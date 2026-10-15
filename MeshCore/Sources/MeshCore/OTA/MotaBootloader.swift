import CryptoKit
import Foundation

extension MotaContainer {
  /// Exact MeshTower V2 SD profile from motatool's format-3 contract. This does
  /// not authorize installation or allow migration from an incompatible live layout.
  func validateMeshTowerBootloader() throws {
    let hardware = Array("NRF_BL_239A0071_TOWER_V2_OTA".utf8)
    let paddedHardware = hardware + Array(repeating: UInt8(0), count: 32 - hardware.count)
    guard kind == .bootloader, flags == 7, codec == 0, blockSize == 1024,
          blockCount == 40, imageSize == 40960, payloadSize == 40960, bytes.count == 41330,
          targetID == 0x1150F50E, Array(bytes[65..<97]) == paddedHardware,
          firmwareVersion != 0, firmwareVersion != .max, firmwareVersion & 255 != 0 else {
      throw MotaError.invalidContainer("Expected the exact signed MeshTower V2 SD bootloader profile")
    }
    let image = Array(bytes[payloadOffset..<(payloadOffset + payloadSize)])
    func u16(_ offset: Int) -> UInt16 { UInt16(image[offset]) | UInt16(image[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { MotaWire.uint32(image, offset) }
    func marker(_ text: String, length: Int) -> [Int] {
      stride(from: 0, through: image.count - length, by: 4).filter {
        Array(image[$0..<($0 + 8)]) == Array(text.utf8)
      }
    }
    let stack = u32(0), reset = u32(4)
    guard stack & 7 == 0, (0x20000000...0x20040000).contains(stack),
          reset & 1 == 1, (0xF4000..<0xFE000).contains(reset & ~1) else {
      throw MotaError.invalidContainer("Invalid bootloader vectors")
    }
    // Reject ambiguous markers, even if another marker's CRC/fields are invalid.
    let identity = 0x9FB4
    guard marker("BLMFCRC1", length: 44) == [identity],
          u16(identity + 8) == 1, u16(identity + 10) == 44,
          u32(identity + 12) == 0xF4000, u32(identity + 16) == 40960,
          u32(identity + 20) == 0x239A0071,
          Array(image[(identity + 24)..<(identity + 40)]) == Array("TOWER_V2_OTA".utf8) + Array(repeating: 0, count: 5) else {
      throw MotaError.invalidContainer("Invalid embedded bootloader identity")
    }
    let crcOffset = identity + 40
    var crc = UInt32.max
    for (index, byte) in image.enumerated() {
      crc ^= (crcOffset..<(crcOffset + 4)).contains(index) ? 0 : UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1 == 1) ? 0xEDB88320 : 0) }
    }
    guard ~crc == u32(crcOffset) else { throw MotaError.invalidContainer("Bootloader CRC mismatch") }
    let ext = identity + 44
    guard Array(image[ext..<(ext + 8)]) == Array("BLM2SOFT".utf8),
          u16(ext + 8) == 2, u16(ext + 10) == 32, u32(ext + 12) == firmwareVersion,
          u16(ext + 16) == 140, u16(ext + 18) == 0xB6, u32(ext + 20) == 0x26000,
          u16(ext + 24) == 1, u16(ext + 26) == 0, u32(ext + 28) == 0 else {
      throw MotaError.invalidContainer("Bootloader continuity must match S140 6.1.1, application base 0x26000 and layout ABI 1")
    }
    let capabilities = marker("MOTABLDR", length: 16)
    guard capabilities.count == 1, let offset = capabilities.first,
          u16(offset + 8) >= 3, u16(offset + 8) != .max,
          u16(offset + 10) == 5, image[offset + 12] == 0x09,
          image[(offset + 13)..<(offset + 16)].allSatisfy({ $0 == 0 }) else {
      throw MotaError.invalidContainer("Bootloader must support ABI 3+, FULL/INPLACE codecs and the SD update profile 0x09")
    }
  }
}
