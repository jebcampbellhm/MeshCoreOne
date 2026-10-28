import CryptoKit
import Foundation

public enum MotaPackageKind: String, Sendable {
  case fullApplication = "Full application"
  case deltaApplication = "Application delta"
  case bootloader = "Bootloader"
}

/// An authenticated package. For deltas, imageHash describes the reconstructed
/// image, not the patch; the receiver verifies that image against its installed base.
public struct MotaContainer: Sendable {
  public let kind: MotaPackageKind
  public let codec: UInt8
  public let flags: UInt8
  public let imageSize: Int
  public let baseHash: Data
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
    try self.init(data: data, archiveOnly: false)
  }

  /// Verifies signed container integrity for storage/serving across hardware.
  /// This is not installation approval; callers must validate the destination
  /// separately before staging or constructing an install command.
  public init(archiveData: Data) throws {
    try self.init(data: archiveData, archiveOnly: true)
  }

  private init(data: Data, archiveOnly: Bool) throws {
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
    let kind: MotaPackageKind
    switch (manifest[0], manifest[1], manifest[56]) {
    case (2, 3, 0): kind = .fullApplication
    case (2, 2, 1), (2, 2, 2): kind = .deltaApplication
    case (3, 7, 0): kind = .bootloader
    default: throw MotaError.invalidContainer("Unsupported package format, flags, or codec; a signed full, delta, or bootloader package is required")
    }
    guard manifest[2] == 0x12,
          manifest[193..<197].allSatisfy({ $0 == 0xFF }) else {
      throw MotaError.invalidContainer("Unsupported hash or non-erased distribution approval")
    }
    let baseHash = Data(manifest[89..<97])
    guard kind == .deltaApplication ? baseHash.contains(where: { $0 != 0 }) : baseHash.allSatisfy({ $0 == 0 }) else {
      throw MotaError.invalidContainer("Invalid base-image hash for this package type")
    }
    guard (1...11).contains(manifest[19]) else {
      throw MotaError.invalidContainer("Unsupported block size")
    }
    let blockSize = 1 << Int(manifest[19])
    let payloadSize = Int(MotaWire.uint32(manifest, 15))
    let imageSize = Int(MotaWire.uint32(manifest, 11))
    let blockCount = (payloadSize + blockSize - 1) / blockSize
    let payloadOffset = 205 + blockCount * 4
    guard payloadSize > 0, (1...Self.maximumSize).contains(imageSize),
          kind == .deltaApplication || imageSize == payloadSize,
          (1...65535).contains(blockCount), payloadOffset + payloadSize + 5 == raw.count else {
      throw MotaError.invalidContainer("Invalid package geometry")
    }
    let hardwareBytes = manifest[57..<89].prefix { $0 != 0 }
    guard let hardwareID = String(bytes: hardwareBytes, encoding: .ascii), !hardwareID.isEmpty,
          manifest[(57 + hardwareBytes.count)..<89].allSatisfy({ $0 == 0 }) else {
      throw MotaError.invalidContainer("Invalid hardware identity")
    }
    let payload = Data(raw[payloadOffset..<(payloadOffset + payloadSize)])
    let imageHash = Data(manifest[24..<56])
    guard kind == .deltaApplication || Data(SHA256.hash(data: payload)) == imageHash else {
      throw MotaError.invalidContainer("Image hash mismatch")
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
    self.kind = kind
    self.codec = manifest[56]
    self.flags = manifest[1]
    self.imageSize = imageSize
    self.baseHash = baseHash
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
    if kind == .bootloader && !archiveOnly { try validateMeshTowerBootloader() }
  }

  /// Additional identity and embedded-image checks for the first supported board.
  public func validateMeshTowerV2() throws {
    if kind == .bootloader { try validateMeshTowerBootloader(); return }
    guard targetID == 0x0A9DBBF0, hardwareID == "Heltec_tower_v2",
          (56...0xC7000).contains(imageSize) else {
      throw MotaError.invalidContainer("Expected a MeshTower V2 SD application image")
    }
    if kind == .deltaApplication {
      guard codec == 2 else { throw MotaError.invalidContainer("MeshTower nRF52 requires an in-place delta (codec 2)") }
      return
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
    result += [codec, flags]
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
