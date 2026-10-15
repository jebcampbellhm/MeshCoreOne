import Foundation
@testable import MeshCore
import Testing

@Suite("Bluetooth mOTA source lifecycle", .timeLimit(.minutes(1)))
struct MotaSourceSessionTests {
  @Test func answersEnumerationBeforeStartCompletesAndClosesOnStop() async throws {
    let transport = SeederTestTransport()
    let session = MeshCoreSession(transport: transport)
    try await session.start()
    let container = try MotaContainer(data: MotaReferenceFixture.container)
    let source = try await session.startMotaSource(container: container)
    #expect(await transport.enumerationAnswered)
    #expect(await transport.channelOpen)
    await source.stop()
    #expect(await transport.channelOpen == false)
    // A stopped attachment must not permanently occupy the session slot.
    _ = try await session.startMotaSource(container: container)
    await session.stop()
    #expect(await transport.channelOpen == false)
  }

  @Test func rejectsSecondActiveSource() async throws {
    let transport = SeederTestTransport()
    let session = MeshCoreSession(transport: transport)
    try await session.start()
    let container = try MotaContainer(data: MotaReferenceFixture.container)
    _ = try await session.startMotaSource(container: container)
    await #expect(throws: MotaError.sourceBusy) {
      try await session.startMotaSource(container: container)
    }
    await session.stop()
  }
}

private actor SeederTestTransport: MotaTransport {
  private let stream: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private var requests: AsyncThrowingStream<Data, Error>.Continuation?
  private(set) var isConnected = false
  private(set) var channelOpen = false
  private(set) var enumerationAnswered = false

  init() {
    (stream, continuation) = AsyncStream<Data>.makeStream()
  }

  var receivedData: AsyncStream<Data> { stream }
  func connect() { isConnected = true }
  func disconnect() {
    isConnected = false
    closeMotaChannel()
    continuation.finish()
  }

  func send(_ data: Data) throws {
    guard isConnected else { throw MeshTransportError.notConnected }
    if data.first == CommandCode.appStart.rawValue {
      var reply = Data([5, 1, 22, 22])
      reply.append(Data(repeating: 1, count: 32))
      reply.append(Data(repeating: 0, count: 12))
      var radio: [UInt8] = []
      MotaWire.append(915_000, to: &radio)
      MotaWire.append(125_000, to: &radio)
      reply.append(contentsOf: radio + [7, 5])
      reply.append(Data("Mota test".utf8))
      continuation.yield(reply)
    } else if data == Data([0x4B, 0]) {
      continuation.yield(Data([0, 0, channelOpen ? 1 : 0, 0, 0, 0, 0]))
    } else if data == Data([0x4B, 1]) {
      // No START reply until the host supplies a catalog response.
      requests?.yield(Data([0x4D, 0x53, 1, 1]))
    }
  }

  func openMotaChannel() -> AsyncThrowingStream<Data, Error> {
    let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    requests = continuation
    channelOpen = true
    return stream
  }

  func sendMotaResponse(_ frame: Data) throws {
    guard frame == Data([0x6D, 0x73, 1, 0, 1, 0x1E]) else { throw MotaError.invalidFrame }
    enumerationAnswered = true
    continuation.yield(Data([0, 1, 3, 1, 0, 1, 0]))
  }

  func closeMotaChannel() {
    channelOpen = false
    requests?.finish()
    requests = nil
  }
}
