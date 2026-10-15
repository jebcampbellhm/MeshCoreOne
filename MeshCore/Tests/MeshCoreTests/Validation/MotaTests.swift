import CryptoKit
import Foundation
@testable import MeshCore
import Testing

@Suite("Full application mOTA and seeder reference vectors")
struct MotaTests {
  @Test func verifiesIndependentSignedFixture() throws {
    let container = try MotaContainer(data: MotaReferenceFixture.container)
    try container.validateMeshTowerV2()
    #expect(container.targetID == 0x0A9DBBF0)
    #expect(container.hardwareID == "Heltec_tower_v2")
    #expect(container.blockCount == 4)
    #expect(container.payloadSize == 97)
    #expect(container.descriptor == MotaReferenceFixture.descriptor)
    #expect(container.descriptor.count == 38)
    #expect(container.descriptor[35] == 0, "Unimplemented compression must not be advertised")
  }

  @Test func mountainRangeUsesRightToLeftPeakBagging() {
    let leaves = (0..<7).map { Data(SHA256.hash(data: Data([UInt8($0)])).prefix(4)) }
    #expect(MotaContainer.merkleRoot(leaves) == MotaReferenceFixture.sevenLeafRoot)
  }

  @Test(arguments: [0, 4, 8, 9, 10, 11, 19, 23, 27, 28, 32, 64, 65, 97, 105, 137, 201, 205, 221, 322])
  func rejectsCorruption(offset: Int) {
    var bytes = MotaReferenceFixture.container
    bytes[offset] ^= 0x80
    #expect(throws: (any Error).self) { try MotaContainer(data: bytes) }
  }

  @Test(arguments: [0, 1, 8, 204, 209, 322])
  func rejectsTruncation(length: Int) {
    #expect(throws: (any Error).self) {
      try MotaContainer(data: Data(MotaReferenceFixture.container.prefix(length)))
    }
  }

  @Test func signedFullOnly() {
    for (offset, value) in [(8, 3), (9, 1), (9, 2), (9, 7), (64, 2), (201, 0x41)] {
      var bytes = MotaReferenceFixture.container
      bytes[offset] = UInt8(value)
      #expect(throws: (any Error).self) { try MotaContainer(data: bytes) }
    }
  }

  @Test func servesOriginalFileWithBoundedReads() throws {
    let container = try MotaContainer(data: MotaReferenceFixture.container)
    let seeder = MotaSeeder(container: container)
    #expect(seeder.response(to: Data([0x4D, 0x53, 1, 1])) == Data([0x6D, 0x73, 1, 0, 1, 0x1E]))
    let descriptor = try #require(seeder.response(to: request(2, [0])))
    #expect(Data(descriptor.dropFirst(4).dropLast()) == MotaReferenceFixture.descriptor)
    var recovered = Data()
    for offset in stride(from: 0, to: container.bytes.count, by: 192) {
      let length = min(192, container.bytes.count - offset)
      var args: [UInt8] = [0]
      MotaWire.append(UInt32(offset), to: &args)
      args += [UInt8(length), 0]
      let reply = try #require(seeder.response(to: request(3, args)))
      #expect(reply.count <= 197)
      #expect(reply[3] == 0)
      #expect(reply.reduce(0, ^) == 0)
      recovered.append(contentsOf: reply.dropFirst(4).dropLast())
    }
    #expect(recovered == container.bytes)
  }

  @Test func rejectsOutOfBoundsAndMalformedRequests() throws {
    let seeder = MotaSeeder(container: try MotaContainer(data: MotaReferenceFixture.container))
    let invalidArguments: [[UInt8]] = [
      [0, 0, 0, 0, 0, 193, 0],
      [0, 255, 255, 255, 255, 1, 0],
      [1, 0, 0, 0, 0, 1, 0],
      [0, 0]
    ]
    for args in invalidArguments {
      #expect(seeder.response(to: request(3, args))?[3] == 1)
    }
    #expect(seeder.response(to: request(9, [0, 0, 0, 0, 0, 0, 0]))?[3] == 1)
    #expect(seeder.response(to: Data([0x4D, 0x53, 1, 0])) == nil)
    #expect(seeder.response(to: Data()) == nil)
    #expect(seeder.response(to: Data(repeating: 0, count: 1000)) == nil)
  }

  @Test func sourceStatusSupportsLegacyAndCurrent() throws {
    let legacy = Data([0, 1, 3, 1, 0, 1, 0])
    let status = try MotaSourceStatus(frame: legacy, action: .start)
    #expect(status.attached && status.channelReady && !status.anotherLinkActive)
    #expect(status.offered == 1 && status.advertised == 1)
    #expect(status.packetsSent == nil)
    let current = try MotaSourceStatus(frame: legacy + Data([255, 255, 255, 255]), action: .start)
    #expect(current.packetsSent == UInt32.max)
    #expect(throws: MotaError.invalidFrame) { try MotaSourceStatus(frame: legacy, action: .stop) }
    #expect(throws: MotaError.invalidFrame) { try MotaSourceStatus(frame: Data([0]), action: .status) }
  }

  @Test func localControlValidation() throws {
    #expect(try CompanionOTAProtocol.localCommand("ota status") == Data([0x4A]) + Data("ota status".utf8))
    #expect(try CompanionOTAProtocol.localReply(Data([0, 2, 79, 75])) == "OK")
    for command in ["", "ota folder on", "ota  fold on", "ota status\nreboot", "ota status;reboot", "reboot", "ota é"] {
      #expect(throws: (any Error).self) { try CompanionOTAProtocol.localCommand(command) }
    }
    #expect(throws: MotaError.invalidFrame) { try CompanionOTAProtocol.localReply(Data([0, 2, 79])) }
  }

  private func request(_ operation: UInt8, _ args: [UInt8]) -> Data {
    Data([0x4D, 0x53, operation] + args + [args.reduce(operation, ^)])
  }
}
