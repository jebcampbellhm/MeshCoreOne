import Testing
@testable import MC1Services

private actor BatchHarness {
  var calls: [String] = []
  var replies: [String] = []
  func send(_ command: String) throws -> String {
    calls.append(command)
    if command == "timeout" { throw RemoteNodeError.timeout }
    return command == "bad" ? "ERR unsupported" : "OK"
  }
  func report(_ reply: String) { replies.append(reply) }
}
struct CLICommandBatchTests {
  @Test func parsesWithoutExecutingAndBoundsInput() throws {
    #expect(try CLICommandBatch.parse("# setup\n\n ota config autofetch off\r\nset gps.sync.interval 12\n") == ["ota config autofetch off", "set gps.sync.interval 12"])
    #expect(throws: (any Error).self) { try CLICommandBatch.parse(String(repeating: "x", count: 121)) }
  }
  @Test(arguments: ["bad", "timeout", "reboot"])
  func stopsWithoutReplayingOrSendingLaterCommands(failure: String) async {
    let harness = BatchHarness(); let batch = CLICommandBatch()
    await #expect(throws: (any Error).self) {
      try await batch.run(["first", failure, "last"], send: { try await harness.send($0) }, report: { _, reply in await harness.report(reply) })
    }
    #expect(await harness.calls == ["first", failure])
  }
  @Test func stopAfterCurrentKeepsCompletedReply() async throws {
    let harness = BatchHarness(); let batch = CLICommandBatch()
    try await batch.run(["first", "last"], send: { try await harness.send($0) }, report: { _, reply in
      await harness.report(reply); await batch.stopAfterCurrent()
    })
    #expect(await harness.calls == ["first"])
    #expect(await harness.replies == ["OK"])
  }
}
