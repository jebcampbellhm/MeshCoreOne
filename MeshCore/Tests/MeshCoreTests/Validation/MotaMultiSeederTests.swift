import Foundation
import CryptoKit
import Testing
import MeshCoreTestSupport
@testable import MeshCore

struct MotaMultiSeederTests {
  @Test func archiveVerificationDoesNotApproveAnotherBoardsBootloaderForInstall() throws {
    var data = try MotaPackageFixtures.data("bootloader")
    // Re-sign a synthetic package with a different target using the public test key.
    data[11] ^= 1
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map(UInt8.init)))
    data.replaceSubrange(137..<201, with: try key.signature(for: Data(data[8..<137])))
    let archived = try MotaContainer(archiveData: data)
    #expect(archived.kind == .bootloader)
    #expect(throws: (any Error).self) { try archived.validateMeshTowerV2() }
    #expect(throws: (any Error).self) { try MotaContainer(data: data) }
    data[137] ^= 1
    #expect(throws: (any Error).self) { try MotaContainer(archiveData: data) }
  }
  func request(_ bytes: [UInt8]) -> Data {
    let frame: [UInt8] = [0x4D, 0x53] + bytes
    return Data(frame + [bytes.reduce(0, ^)])
  }
  @Test func servesEachIndexAndBoundsReads() throws {
    let full = try MotaContainer(data: MotaPackageFixtures.data("full"))
    let boot = try MotaContainer(data: MotaPackageFixtures.data("bootloader"))
    let seeder = try MotaSeeder(containers: [full, boot])
    #expect(seeder.response(to: request([1]))?[4] == 2)
    for (index, package) in [full, boot].enumerated() {
      let descriptor = try #require(seeder.response(to: request([2, UInt8(index)])))
      #expect(Data(descriptor.dropFirst(4).dropLast()) == package.descriptor)
      let reply = try #require(seeder.response(to: request([3, UInt8(index), 0, 0, 0, 0, 32, 0])))
      #expect(Data(reply.dropFirst(4).dropLast()) == package.bytes.prefix(32))
    }
    #expect(seeder.response(to: request([2, 2]))?[3] == 1)
    #expect(throws: (any Error).self) { try MotaSeeder(containers: [full, full]) }
  }
}
