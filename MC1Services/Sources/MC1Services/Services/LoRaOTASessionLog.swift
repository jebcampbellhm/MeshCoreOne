import Foundation

/// Bounded, local OTA diagnostics. Contains no login passwords or firmware bytes.
public actor LoRaOTASessionLog {
  public static let maximumBytes = 128 * 1024
  public static let retainedSessionCount = 2
  public nonisolated let url: URL
  private var reachedLimit = false

  public init(directory: URL? = nil) throws {
    let directory = try (directory ?? Self.defaultDirectory()).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
    url = directory.appendingPathComponent("session-\(timestamp)-\(UUID().uuidString).txt")
    try Data("MC1OTA transfer session\n".utf8).write(to: url, options: .atomic)
    let oldLogs = try Self.recentLogs(directory: directory).filter { $0.lastPathComponent != url.lastPathComponent }
    for old in oldLogs.dropFirst(Self.retainedSessionCount - 1) {
      try FileManager.default.removeItem(at: old)
    }
  }

  public func append(_ message: String) {
    guard !reachedLimit else { return }
    do {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      let line = Data("\(Date().ISO8601Format()) \(message)\n".utf8)
      let limit = Data("[Session log size limit reached; further entries omitted.]\n".utf8)
      if size + UInt64(line.count + limit.count) > UInt64(Self.maximumBytes) {
        reachedLimit = true
        if size + UInt64(limit.count) <= UInt64(Self.maximumBytes) { try handle.write(contentsOf: limit) }
      } else {
        try handle.write(contentsOf: line)
      }
    } catch {
      // Logging must never interfere with radio cleanup or transfer progress.
      reachedLimit = true
    }
  }

  public nonisolated static func recentLogs(directory: URL? = nil) throws -> [URL] {
    let directory = try (directory ?? defaultDirectory()).resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "txt" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  private nonisolated static func defaultDirectory() throws -> URL {
    try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("MC1OTA-SessionLogs", isDirectory: true)
  }
}
