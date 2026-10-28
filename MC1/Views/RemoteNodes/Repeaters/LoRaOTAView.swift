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
  @State private var frequency = "909.5"
  private static let bandwidthSteps = [62.5, 125.0, 250.0, 500.0]
  @State private var bandwidthIndex = 3
  private var bandwidth: Double { Self.bandwidthSteps[bandwidthIndex] }
  @State private var spreadingFactor = 5
  @State private var codingRate = 5
  @State private var minutes = 120
  @State private var password = ""
  @State private var directLink = true
  @State private var otaSpeed = 2.0
  @State private var clearExistingDownload = false
  @State private var message = "Select a signed full, delta, or bootloader .mota for MeshTower V2 SD."
  @State private var transfer: Task<Void, Never>?
  @State private var sessionLogs: [URL] = []
  @State private var installCommand = ""
  @State private var copiedCommand = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Signed firmware") {
          Button(loading ? "Checking firmware…" : "Load .mota file") { importing = true }
            .disabled(loading || transfer != nil)
          if let container {
            Text(filename)
            LabeledContent("Package", value: container.kind.rawValue)
            LabeledContent("Hardware", value: container.hardwareID)
            LabeledContent("Version", value: String(container.firmwareVersion))
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(container.bytes.count), countStyle: .file))
            Text("Signature and file integrity verified. The repeater must already trust this signing key.")
              .font(.footnote)
            if container.kind == .deltaApplication {
              Text("The running firmware must match this delta's base. The repeater verifies the reconstructed image during application.")
                .font(.footnote)
              Text("Base: " + container.baseHash.map { String(format: "%02X", $0) }.joined())
                .font(.caption.monospaced()).textSelection(.enabled)
            }
            if container.kind == .bootloader {
              Text("SD bootloader update: requires an already compatible self-update bootloader. This screen stages it and reports the separate install command after exact ID/hash verification.")
                .font(.footnote)
            }
            Text("Signer: " + container.signer.map { String(format: "%02x", $0) }.joined())
              .font(.caption.monospaced()).textSelection(.enabled)
          }
        }
        Section("Temporary radio") {
          TextField("Frequency (MHz)", text: $frequency).keyboardType(.decimalPad)
          Stepper("Bandwidth: \(bandwidth.formatted()) kHz", value: $bandwidthIndex,
                  in: 0...(Self.bandwidthSteps.count - 1))
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
          Picker("OTA speed", selection: $otaSpeed) {
            ForEach([0.5, 1.0, 1.5, 2.0, 2.5, 3.0], id: \.self) { speed in
              Text("\(speed.formatted())×").tag(speed)
            }
          }.disabled(transfer != nil)
          Text("Sets both devices during transfer, then restores each previous speed. Faster pacing does not override radio airtime or automatic loss recovery.")
            .font(.footnote)
          Toggle("Clear existing download before transfer", isOn: $clearExistingDownload)
            .disabled(transfer != nil)
          Text("Stops the current download before starting. Staged install data is cleared; firmware may retain archive partials for resume. This option resets after each attempt.")
            .font(.footnote)
          Text(message).textSelection(.enabled)
          if transfer != nil {
            ProgressView()
            Button("Stop seeding and restore radios", role: .destructive) { transfer?.cancel() }
          } else {
            Button("Seed and pull to repeater SD") { start() }
              .disabled(container == nil || !directLink || loading)
          }
        }
        Section("Companion requirement") {
          Text("Requires full companion firmware from mikecarper.github.io/MeshCore with Bluetooth MOTA support.")
            .font(.footnote)
          Link("Get full companion firmware", destination: URL(string: "https://mikecarper.github.io/MeshCore/")!)
        }
        Section("Manual installation") {
          Button("Read OTA status for install command") { refreshInstallCommand() }
            .disabled(transfer != nil || loading)
          if !installCommand.isEmpty {
            TextField("Install command", text: .constant(installCommand), axis: .vertical)
              .font(.body.monospaced())
              .textSelection(.enabled)
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)
            Button(copiedCommand ? "Copied" : "Copy install command", systemImage: "doc.on.doc") {
              UIPasteboard.general.string = installCommand
              copiedCommand = true
            }
            .disabled(transfer != nil || loading)
          }
          Text("Copy the command, open this repeater's CLI, and paste it when ready. Installation may reboot the repeater. Reading status and copying do not install anything.")
            .font(.footnote)
        }
        if !sessionLogs.isEmpty {
          Section("Recent session logs") {
            ForEach(Array(sessionLogs.enumerated()), id: \.element) { index, url in
              ShareLink(item: url) {
                Label(index == 0 ? "Share latest session log" : "Share previous session log", systemImage: "square.and.arrow.up")
              }
            }
            Text("Only the last two sessions are kept, up to 128 KB each. Passwords and firmware contents are excluded.")
              .font(.footnote)
          }.disabled(transfer != nil)
        }
      }
      .navigationTitle("LoRa firmware transfer")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(transfer != nil || loading) } }
      .interactiveDismissDisabled(transfer != nil || loading)
      .task { sessionLogs = (try? LoRaOTASessionLog.recentLogs()) ?? [] }
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
    installCommand = ""
    copiedCommand = false
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
      let log = try LoRaOTASessionLog()
      installCommand = ""
      copiedCommand = false
      sessionLogs = (try? LoRaOTASessionLog.recentLogs()) ?? []
      let workflow = LoRaOTAWorkflow.connected(session: services.session, remote: services.remoteNodeService,
        sessionID: session.id, password: password.isEmpty ? nil : password,
        log: { await log.append($0) })
      let shouldClearDownload = clearExistingDownload
      clearExistingDownload = false
      transfer = Task {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        await log.append("MC1OTA \(version) (\(build)); iOS \(UIDevice.current.systemVersion); \(radio.command); clear existing download: \(shouldClearDownload)")
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer; transfer = nil; password = "" }
        do {
          installCommand = try await workflow.run(container: container, radio: radio, speed: otaSpeed, clearExistingDownload: shouldClearDownload) { status in
            await log.append("Progress: \(status)")
            await MainActor.run { message = status }
          }
          await log.append("Session completed")
        } catch {
          message = "\(message)\n\(error.localizedDescription)"
          await log.append("Session ended: \(message)")
        }
      }
    } catch { message = error.localizedDescription }
  }

  private func refreshInstallCommand() {
    installCommand = ""
    copiedCommand = false
    guard let services = appState.services,
          appState.connectedDevice?.radioID == session.radioID else {
      message = "Reconnect the companion used for this repeater session."
      return
    }
    loading = true
    transfer = Task {
      defer { loading = false; transfer = nil; password = "" }
      do {
        message = "Reading repeater installation status"
        let workflow = LoRaOTAWorkflow.connected(session: services.session, remote: services.remoteNodeService,
          sessionID: session.id, password: password.isEmpty ? nil : password)
        installCommand = try await workflow.readInstallCommand()
        message = "Completed download found. Copy the install command below and paste it into this repeater's CLI."
      } catch { message = error.localizedDescription }
    }
  }
}
