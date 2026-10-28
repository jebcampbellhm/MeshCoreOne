import SwiftUI
import MC1Services

struct RepeaterCommandBatchView: View {
  let session: RemoteNodeSessionDTO
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var results: [String] = []
  @State private var message = "Paste one command per line. Nothing is sent until you tap Run."
  @State private var running = false
  @State private var runner = CLICommandBatch()
  @State private var task: Task<Void, Never>?
  var body: some View {
    NavigationStack {
      Form {
        Section("Send to \(session.name)") {
          Text(session.publicKey.prefix(6).map { String(format: "%02X", $0) }.joined()).font(.caption.monospaced())
          TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 180)
            .autocorrectionDisabled().textInputAutocapitalization(.never).disabled(running)
          Text("One command per line; blank lines and # comments are ignored. Commands run in order and stop at the first error or timeout. Input and results are not saved as presets or OTA session logs.").font(.footnote)
          if running {
            Button("Stop after current command") { Task { await runner.stopAfterCurrent() } }
          } else {
            Button("Run commands on \(session.name)") { run() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        Section("Results") {
          Text(message).textSelection(.enabled)
          ForEach(Array(results.enumerated()), id: \.offset) { index, result in
            Text("\(index + 1). \(result)").font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      }
      .navigationTitle("Setup commands")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(running) } }
      .interactiveDismissDisabled(running)
      .onDisappear { task?.cancel(); text = ""; results = [] }
    }
  }
  private func run() {
    guard let services = appState.services, appState.connectedDevice?.radioID == session.radioID else {
      message = "Connect the companion used for this repeater."; return
    }
    do {
      let lines = try CLICommandBatch.parse(text)
      running = true; results = []; message = "Running \(lines.count) commands"
      task = Task {
        defer { running = false; task = nil }
        do {
          let login = try await services.remoteNodeService.login(sessionID: session.id)
          guard login.isAdmin else { throw LoRaOTAError.message("Administrator login required") }
          try await runner.run(lines, send: { command in
            try await services.remoteNodeService.sendSingleCLICommand(sessionID: session.id, command: command)
          }, report: { _, reply in await MainActor.run { results.append(reply) } })
          message = "Finished or stopped after the current command. \(results.count) of \(lines.count) replies received."
        } catch { message = error.localizedDescription }
      }
    } catch { message = error.localizedDescription }
  }
}
