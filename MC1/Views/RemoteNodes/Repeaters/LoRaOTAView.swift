import Foundation
import MC1Services
import MeshCore
import SwiftUI
import UniformTypeIdentifiers

struct LoRaOTAView: View {
  let session: RemoteNodeSessionDTO
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var container: MotaContainer?
  @State private var filename = ""
  @State private var importing = false
  @State private var loading = false
  @State private var frequency = ""
  @State private var bandwidth = 250.0
  @State private var spreadingFactor = 5
  @State private var codingRate = 5
  @State private var minutes = 120
  @State private var password = ""
  @State private var directLink = false
  @State private var message = "Select a signed full application update."
  @State private var transfer: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      Form {
        Section("Signed firmware") {
          Button(loading ? "Checking firmware…" : "Load .mota file") { importing = true }
            .disabled(loading || transfer != nil)
          if let container {
            Text(filename)
            LabeledContent("Hardware", value: container.hardwareID)
            LabeledContent("Version", value: String(container.firmwareVersion))
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(container.bytes.count), countStyle: .file))
            Text("Signature and file integrity verified. The repeater must already trust this signing key.")
              .font(.footnote)
            Text("Signer: " + container.signer.map { String(format: "%02x", $0) }.joined())
              .font(.caption.monospaced()).textSelection(.enabled)
          }
        }
        Section("Temporary radio") {
          TextField("Frequency (MHz)", text: $frequency).keyboardType(.decimalPad)
          Picker("Bandwidth (kHz)", selection: $bandwidth) {
            ForEach([62.5, 125.0, 250.0, 500.0], id: \.self) { Text($0.formatted()).tag($0) }
          }
          Stepper("Spreading factor: \(spreadingFactor)", value: $spreadingFactor, in: 5...12)
          Stepper("Coding rate: 4/\(codingRate)", value: $codingRate, in: 5...8)
          Stepper("Window: \(minutes) minutes", value: $minutes, in: 5...120, step: 5)
          Text("Both radios use these settings temporarily, then return to their saved settings. Choose a frequency supported by both boards.")
            .font(.footnote)
        }.disabled(transfer != nil)
        Section("Repeater access") {
          SecureField("Admin password (blank uses saved password)", text: $password)
          Toggle("Repeater is directly reachable", isOn: $directLink)
          Text("This first version moves only the companion and this repeater. Keep this screen open and the phone connected during transfer.")
            .font(.footnote)
        }.disabled(transfer != nil)
        Section("Transfer") {
          Text(message).textSelection(.enabled)
          if transfer != nil {
            ProgressView()
            Button("Stop seeding and restore radios", role: .destructive) { transfer?.cancel() }
          } else {
            Button("Seed and pull to repeater SD") { start() }
              .disabled(container == nil || !directLink || loading)
          }
        }
      }
      .navigationTitle("LoRa firmware transfer")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(transfer != nil || loading) } }
      .interactiveDismissDisabled(transfer != nil || loading)
      .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
        load(result)
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background { transfer?.cancel() }
      }
      .onDisappear { transfer?.cancel() }
    }
  }

  private func load(_ result: Result<URL, any Error>) {
    container = nil
    loading = true
    Task {
      do {
        let url = try result.get()
        let validated = try await Task.detached {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let handle = try FileHandle(forReadingFrom: url)
          defer { try? handle.close() }
          let data = try handle.read(upToCount: MotaContainer.maximumSize + 1) ?? Data()
          let parsed = try MotaContainer(data: data)
          try parsed.validateMeshTowerV2()
          return parsed
        }.value
        container = validated
        filename = url.lastPathComponent
        message = "Ready. Enter temporary radio options to begin."
      } catch { message = error.localizedDescription }
      loading = false
    }
  }

  private func start() {
    guard let container, let services = appState.services else { message = "Connect the companion first."; return }
    guard appState.connectedDevice?.radioID == session.radioID else {
      message = "Reconnect the companion used for this repeater session."
      return
    }
    do {
      let radio = try OTATemporaryRadio(frequencyMHz: Double(frequency.replacingOccurrences(of: ",", with: ".")) ?? .nan,
        bandwidthKHz: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate, minutes: minutes)
      let workflow = LoRaOTAWorkflow.connected(session: services.session, remote: services.remoteNodeService,
        sessionID: session.id, password: password.isEmpty ? nil : password)
      transfer = Task {
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer; transfer = nil; password = "" }
        do {
          try await workflow.run(container: container, radio: radio) { status in
            await MainActor.run { message = status }
          }
        } catch { message = error.localizedDescription }
      }
    } catch { message = error.localizedDescription }
  }
}
