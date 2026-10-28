import Foundation

/// Deliberately sequential. An ambiguous mutation is never automatically replayed.
public actor CLICommandBatch {
  private var stopRequested = false
  private var running = false
  public init() {}
  public func stopAfterCurrent() { stopRequested = true }
  public nonisolated static func parse(_ text: String) throws -> [String] {
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    guard (1...50).contains(lines.count), lines.allSatisfy({ $0.utf8.count <= 120 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else {
      throw LoRaOTAError.message("Enter 1–50 commands, one per line, at most 120 UTF-8 bytes each. Blank lines and # comments are ignored.")
    }
    return lines
  }
  public func run(_ lines: [String], send: @Sendable (String) async throws -> String,
                  report: @Sendable (Int, String) async -> Void) async throws {
    guard !running else { throw LoRaOTAError.message("A command batch is already running") }
    running = true; stopRequested = false
    defer { running = false }
    for (index, line) in lines.enumerated() {
      guard !stopRequested else { return }
      try Task.checkCancellation()
      do {
        let reply = try await send(line)
        await report(index, reply)
        let normalized = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("err") || normalized.hasPrefix("unknown command") || normalized.hasPrefix("invalid") {
          throw LoRaOTAError.message("Command \(index + 1) was rejected. Remaining commands were not sent.")
        }
        if ["reboot", "poweroff", "reset", "start ota"].contains(line.lowercased()) {
          throw LoRaOTAError.message("Stopped after a connection-changing command. Reconnect and review before continuing.")
        }
      } catch {
        throw LoRaOTAError.message("Stopped at command \(index + 1): \(error.localizedDescription) No automatic retry; the command may have taken effect.")
      }
    }
  }
}
