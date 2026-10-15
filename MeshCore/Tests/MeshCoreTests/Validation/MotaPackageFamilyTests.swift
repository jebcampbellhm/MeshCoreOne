import CryptoKit
import Foundation
import MeshCoreTestSupport
import Testing
@testable import MeshCore

struct MotaPackageFamilyTests {
  @Test(arguments: ["full", "delta", "bootloader"])
  func validatesAndServesEachFamily(name: String) throws {
    let data = try MotaPackageFixtures.data(name)
    let package = try MotaContainer(data: data)
    try package.validateMeshTowerV2()
    let expected: MotaPackageKind = name == "full" ? .fullApplication : name == "delta" ? .deltaApplication : .bootloader
    #expect(package.kind == expected)
    #expect(package.descriptor[12] == data[64])
    #expect(package.descriptor[13] == data[9])
    #expect(package.descriptor == (try MotaPackageFixtures.data(name, extension: "descriptor")))
    if name == "delta" {
      #expect(package.imageHash == Data(SHA256.hash(data: try MotaPackageFixtures.data("target", extension: "bin"))))
      #expect(package.imageSize != package.payloadSize)
      #expect(package.codec == 2)
    }
    if name == "bootloader" {
      #expect(package.bytes.count == 41330)
      #expect(package.targetID == 0x1150F50E)
      #expect(package.blockCount == 40)
    }
    let seeder = MotaSeeder(container: package)
    var restored = Data()
    for offset in stride(from: 0, to: data.count, by: 192) {
      let size = min(192, data.count - offset)
      var frame: [UInt8] = [0x4D, 0x53, 3, 0]
      MotaWire.append(UInt32(offset), to: &frame)
      frame += [UInt8(size), 0]
      frame.append(frame.dropFirst(2).reduce(0, ^))
      let reply = try #require(seeder.response(to: Data(frame)))
      #expect(reply[3] == 0 && reply.reduce(0, ^) == 0)
      restored.append(reply.dropFirst(4).dropLast())
    }
    #expect(restored == data)
  }

  @Test(arguments: [0, 4, 136, 138, 140, 0x9FB4 + 20, 0x9FB4 + 24, 0x9FB4 + 40,
                    0x9FB4 + 44, 0x9FB4 + 56, 0x9FB4 + 62, 0x9FB4 + 64, 0x9FB4 + 72])
  func rejectsSignedInvalidBootloader(offset: Int) throws {
    var bytes = Array(try MotaPackageFixtures.data("bootloader"))
    let start = 205 + 40 * 4
    bytes[start + offset] ^= 0x01
    // Repair every integrity layer so this exercises the payload contract, not
    // merely a failed outer signature or hash. Preserve a deliberately bad CRC.
    if offset != 0x9FB4 + 40 { repairCRC(&bytes, payload: start) }
    try resign(&bytes, payload: start, blockSize: 1024)
    #expect(throws: (any Error).self) { try MotaContainer(data: Data(bytes)) }
  }

  @Test func rejectsSignedWrongBootloaderProfileAndAmbiguity() throws {
    let start = 365
    for mutation in 0..<3 {
      var bytes = Array(try MotaPackageFixtures.data("bootloader"))
      if mutation == 0 { bytes[start + 140] = 0x0A } // Same board, wrong internal-storage profile.
      if mutation == 1 { bytes.replaceSubrange((start + 256)..<(start + 272), with: bytes[(start + 128)..<(start + 144)]) }
      if mutation == 2 { bytes[8] = 2 } // Boot flags may not masquerade as an application.
      repairCRC(&bytes, payload: start)
      try resign(&bytes, payload: start, blockSize: 1024)
      #expect(throws: (any Error).self) { try MotaContainer(data: Data(bytes)) }
    }
  }

  @Test func rejectsWrongDeltaBaseAndCodecGeometry() throws {
    for mutation in 0..<3 {
      var bytes = Array(try MotaPackageFixtures.data("delta"))
      let count = (Int(MotaWire.uint32(bytes, 23)) + 31) / 32
      if mutation == 0 { bytes.replaceSubrange(97..<105, with: Array(repeating: 0, count: 8)) }
      if mutation == 1 { bytes[64] = 0 }
      if mutation == 2 { bytes[9] = 3 }
      try resign(&bytes, payload: 205 + count * 4, blockSize: 32, full: false)
      #expect(throws: (any Error).self) { try MotaContainer(data: Data(bytes)) }
    }
  }

  private func repairCRC(_ bytes: inout [UInt8], payload: Int) {
    let offset = payload + 0x9FB4 + 40
    bytes.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0, 0])
    var crc = UInt32.max
    for byte in bytes[payload..<(bytes.count - 5)] {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
    }
    var value: [UInt8] = []
    MotaWire.append(~crc, to: &value)
    bytes.replaceSubrange(offset..<(offset + 4), with: value)
  }

  private func resign(_ bytes: inout [UInt8], payload: Int, blockSize: Int, full: Bool = true) throws {
    let image = Data(bytes[payload..<(bytes.count - 5)])
    if full { bytes.replaceSubrange(32..<64, with: SHA256.hash(data: image)) }
    let leaves = stride(from: 0, to: image.count, by: blockSize).map {
      MotaContainer.shortHash(image.subdata(in: $0..<min($0 + blockSize, image.count)))
    }
    bytes.replaceSubrange(205..<payload, with: leaves.flatMap { $0 })
    bytes.replaceSubrange(28..<32, with: MotaContainer.merkleRoot(leaves))
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map(UInt8.init)))
    bytes.replaceSubrange(137..<201, with: try key.signature(for: Data(bytes[8..<137])))
  }
}
