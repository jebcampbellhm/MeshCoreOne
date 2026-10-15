import CryptoKit
import Foundation

/// A fully verified, signed format-2 application container. Verification proves
/// integrity; the receiver still decides whether the embedded signer is trusted.
public struct MotaContainer: Sendable {
  public let bytes: Data
  public let targetID: UInt32
  public let firmwareVersion: UInt32
  public let hardwareID: String
  public let signer: Data
  public let imageHash: Data
  public let manifestID: Data
  public let blockCount: Int
  public let blockSize: Int
  public let payloadOffset: Int
  public let payloadSize: Int

  /// Bounds memory and verification work before parsing untrusted geometry.
  public static let maximumSize = 2 * 1024 * 1024

  public init(data: Data) throws {
    guard (210...Self.maximumSize).contains(data.count) else {
      throw MotaError.invalidContainer("Invalid container size")
    }
    let bytes = Data([UInt8](data))
    let raw = [UInt8](bytes)
    guard Array(raw.prefix(4)) == Array("mOTA".utf8),
          MotaWire.uint32(raw, 4) == UInt32(raw.count),
          Array(raw.suffix(5)) == Array("vk496".utf8) else {
      throw MotaError.invalidContainer("Invalid container framing")
    }
    let manifest = Array(raw[8..<205])
    guard manifest[0] == 2, manifest[1] == 3, manifest[2] == 0x12,
          manifest[56] == 0, manifest[89..<97].allSatisfy({ $0 == 0 }),
          manifest[193..<197].allSatisfy({ $0 == 0xFF }) else {
      throw MotaError.invalidContainer("Only unapproved, signed full application images are supported")
    }
    guard (1...11).contains(manifest[19]) else {
      throw MotaError.invalidContainer("Unsupported block size")
    }
    let blockSize = 1 << Int(manifest[19])
    let payloadSize = Int(MotaWire.uint32(manifest, 15))
    let blockCount = (payloadSize + blockSize - 1) / blockSize
    let payloadOffset = 205 + blockCount * 4
    guard payloadSize > 0, MotaWire.uint32(manifest, 11) == UInt32(payloadSize),
          (1...65535).contains(blockCount), payloadOffset + payloadSize + 5 == raw.count else {
      throw MotaError.invalidContainer("Invalid application geometry")
    }
    let hardwareBytes = manifest[57..<89].prefix { $0 != 0 }
    guard let hardwareID = String(bytes: hardwareBytes, encoding: .utf8), !hardwareID.isEmpty else {
      throw MotaError.invalidContainer("Invalid hardware identity")
    }
    let payload = Data(raw[payloadOffset..<(payloadOffset + payloadSize)])
    let imageHash = Data(manifest[24..<56])
    guard Data(SHA256.hash(data: payload)) == imageHash else {
      throw MotaError.invalidContainer("Application hash mismatch")
    }
    var leaves: [Data] = []
    leaves.reserveCapacity(blockCount)
    for index in 0..<blockCount {
      let start = payloadOffset + index * blockSize
      let end = min(start + blockSize, payloadOffset + payloadSize)
      let leaf = Self.shortHash(Data(raw[start..<end]))
      guard leaf == Data(raw[(205 + index * 4)..<(209 + index * 4)]) else {
        throw MotaError.invalidContainer("Block hash mismatch")
      }
      leaves.append(leaf)
    }
    let manifestID = Data(manifest[20..<24])
    guard Self.merkleRoot(leaves) == manifestID else {
      throw MotaError.invalidContainer("Merkle root mismatch")
    }
    let signer = Data(manifest[97..<129])
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: signer)
    guard key.isValidSignature(Data(manifest[129..<193]), for: Data(manifest[0..<129])) else {
      throw MotaError.invalidContainer("Invalid firmware signature")
    }
    self.bytes = bytes
    self.targetID = MotaWire.uint32(manifest, 3)
    self.firmwareVersion = MotaWire.uint32(manifest, 7)
    self.hardwareID = hardwareID
    self.signer = signer
    self.imageHash = imageHash
    self.manifestID = manifestID
    self.blockCount = blockCount
    self.blockSize = blockSize
    self.payloadOffset = payloadOffset
    self.payloadSize = payloadSize
  }

  /// Additional identity and embedded-image checks for the first supported board.
  public func validateMeshTowerV2() throws {
    guard targetID == 0x0A9DBBF0, hardwareID == "Heltec_tower_v2",
          (56...0xC7000).contains(payloadSize) else {
      throw MotaError.invalidContainer("Expected a MeshTower V2 SD application image")
    }
    let image = [UInt8](bytes[payloadOffset..<(payloadOffset + payloadSize)])
    let end = Array(image.suffix(56))
    guard Array(end[0..<4]) == Array("EndF".utf8),
          MotaWire.uint32(end, 4) == UInt32(payloadSize - 56),
          Data(SHA256.hash(data: Data(image.dropLast(56))).prefix(8)) == Data(end[8..<16]),
          MotaWire.uint32(end, 16) == firmwareVersion,
          MotaWire.uint32(end, 20) == targetID,
          Data(end[24..<56]) == Data(bytes[65..<97]) else {
      throw MotaError.invalidContainer("Embedded application identity does not match the manifest")
    }
  }

  /// Descriptor without DEFLATE capability; reads always return original bytes.
  public var descriptor: Data {
    var result = [UInt8](manifestID)
    MotaWire.append(targetID, to: &result)
    MotaWire.append(firmwareVersion, to: &result)
    result += [0, 3]
    for value in [bytes.count, 205, blockCount, payloadOffset, payloadSize] {
      MotaWire.append(UInt32(value), to: &result)
    }
    result += [UInt8(blockSize.trailingZeroBitCount), 0, 0, 0]
    return Data(result)
  }

  static func shortHash(_ bytes: Data) -> Data {
    Data(SHA256.hash(data: bytes).prefix(4))
  }

  /// Merkle mountain range with remaining peaks bagged right-to-left.
  static func merkleRoot(_ leaves: [Data]) -> Data {
    var peaks: [Data?] = []
    for leaf in leaves {
      var current = leaf
      var level = 0
      while level < peaks.count, let left = peaks[level] {
        current = shortHash(left + current)
        peaks[level] = nil
        level += 1
      }
      if level == peaks.count { peaks.append(current) } else { peaks[level] = current }
    }
    var result: Data?
    for peak in peaks.compactMap({ $0 }) {
      result = result.map { shortHash(peak + $0) } ?? peak
    }
    return result ?? Data(repeating: 0, count: 4)
  }
}

public enum MotaError: Error, LocalizedError, Sendable, Equatable {
  case invalidContainer(String)
  case invalidFrame
  case unsupported
  case sourceBusy

  public var errorDescription: String? {
    switch self {
    case let .invalidContainer(reason): reason
    case .invalidFrame: "Malformed OTA protocol response"
    case .unsupported: "This companion does not expose the Bluetooth OTA service"
    case .sourceBusy: "Another firmware source is already active"
    }
  }
}

enum MotaWire {
  static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
  }

  static func append(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
  }
}
