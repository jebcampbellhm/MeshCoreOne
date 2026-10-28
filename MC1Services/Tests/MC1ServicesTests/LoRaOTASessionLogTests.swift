import Foundation
import Testing
@testable import MC1Services

struct LoRaOTASessionLogTests {
  @Test func retainsOnlyTwoSessionsAndPreservesOtherFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try LoRaOTASessionLog(directory: directory)
    let unrelated = directory.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: unrelated)
    let second = try LoRaOTASessionLog(directory: directory)
    let third = try LoRaOTASessionLog(directory: directory)
    await third.append("Progress: test")
    let logs = try LoRaOTASessionLog.recentLogs(directory: directory)
    #expect(Set(logs.map(\.lastPathComponent)) == Set([second.url, third.url].map(\.lastPathComponent)))
    #expect(!FileManager.default.fileExists(atPath: first.url.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(try String(contentsOf: third.url, encoding: .utf8).contains("Progress: test"))
  }

  @Test func capsLogSizeAndStopsAppending() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try LoRaOTASessionLog(directory: directory)
    for _ in 0..<150 { await log.append(String(repeating: "x", count: 1024)) }
    let capped = try Data(contentsOf: log.url)
    await log.append("must not append")
    #expect(capped.count <= LoRaOTASessionLog.maximumBytes)
    #expect(capped.count > 120 * 1024)
    #expect(String(decoding: capped, as: UTF8.self).contains("size limit reached"))
    #expect(try Data(contentsOf: log.url) == capped)
  }
}
