import Foundation
@testable import MeshCore
import Testing

@Suite("OTA reply routing")
struct MotaReplyRoutingTests {
  @Test func localRepliesKeepPayloadAndAllowPushesBetweenFragments() async throws {
    let session = MeshCoreSession(transport: MockTransport())
    let events = await session.events()
    await session.prepareOTAReply(for: 0x4A)
    #expect(await session.consumeOTAReply(Data([0, 5, 104, 101])))
    #expect(await session.consumeOTAReply(Data([0x80, 1, 2])) == false)
    #expect(await session.consumeOTAReply(Data([108, 108, 111])))
    var iterator = events.makeAsyncIterator()
    guard case let .otaControlReply(frame) = await iterator.next() else {
      Issue.record("Expected a complete OTA reply")
      return
    }
    #expect(try CompanionOTAProtocol.localReply(frame) == "hello")
    #expect(await session.consumeOTAReply(Data([0])) == false)
    await session.stop()
  }

  @Test func sourcePayloadIsNotReducedToUInt32() async throws {
    let session = MeshCoreSession(transport: MockTransport())
    let events = await session.events()
    await session.prepareOTAReply(for: 0x4B)
    let bytes = Data([0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0])
    #expect(await session.consumeOTAReply(bytes))
    var iterator = events.makeAsyncIterator()
    guard case let .otaControlReply(frame) = await iterator.next() else {
      Issue.record("Expected source status")
      return
    }
    #expect(try MotaSourceStatus(frame: frame, action: .status).packetsSent == 2)
    await session.stop()
  }

  @Test func errorsAndOrdinaryRepliesUseExistingParser() async {
    let session = MeshCoreSession(transport: MockTransport())
    await session.prepareOTAReply(for: 0x4B)
    #expect(await session.consumeOTAReply(Data([1, 4])) == false)
    await session.prepareOTAReply(for: nil)
    #expect(await session.consumeOTAReply(Data([0])) == false)
    await session.stop()
  }
}
