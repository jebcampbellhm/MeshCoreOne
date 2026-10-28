import Foundation
import MeshCore

/// Parses the reference firmware's bounded text replies; missing capabilities
/// never imply support. Device-side trust/continuity checks remain authoritative.
enum OTAPackageCompatibility {
  static func fields(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (1..<match.numberOfRanges).map {
      Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
    }
  }

  static func validate(_ package: MotaContainer, status: String, identity: String, storage: String) throws {
    guard fields(#"\bhw=([^ |]+)"#, in: status)?.first == "Heltec_tower_v2",
          fields(#"\btarget:([0-9A-Fa-f]{8})\b"#, in: status)?.first?.uppercased() == "0A9DBBF0" else {
      throw LoRaOTAError.message("Repeater does not report the required MeshTower V2 application target.")
    }
    guard let maximum = fields(#"\bmaxblk:(\d+)\b"#, in: status)?.first.flatMap(Int.init),
          package.blockSize <= maximum,
          let caps = fields(#"\babi=(\d+)\s+codecs=0x([0-9A-Fa-f]+)\b"#, in: identity),
          let abi = Int(caps[0]), let codecs = UInt16(caps[1], radix: 16),
          abi >= (package.kind == .bootloader ? 3 : 2),
          package.kind != .bootloader || codecs == 5,
          codecs & (UInt16(1) << package.codec) != 0 else {
      throw LoRaOTAError.message("Repeater bootloader ABI, codec mask, or maximum block size does not support this package.")
    }
    // Fixed SD builds route `ota storage` to the QSPI-only diagnostic. Their
    // status and self replies instead identify the SD backend and apply support.
    // Accept only that exact unsupported-command reply, never an actual media
    // error or an adaptive store selecting internal flash. The receiver still
    // checks SD availability when it opens the receive slot for the pull.
    let fixedSD = storage.trimmingCharacters(in: .whitespacesAndNewlines)
      == "ERR this build does not use a QSPI OTA store"
      && fields(#"\bbl:([^ |]+)"#, in: status)?.first == "SD"
      && fields(#"\bbootloader: SD apply OK \(abi=\d+ codecs=0x[0-9A-Fa-f]+\)"#, in: identity) != nil
    guard storage.hasPrefix("OTA storage: SD staging;") || fixedSD else {
      throw LoRaOTAError.message("Mounted SD staging and a compatible OTAFIX bootloader are required. \(storage)")
    }
    if package.kind == .deltaApplication {
      let base = package.baseHash.map { String(format: "%02X", $0) }.joined()
      guard fields(#"\bbase_hash=([0-9A-Fa-f]{16})\b"#, in: identity)?.first?.uppercased() == base else {
        throw LoRaOTAError.message("Delta base does not match the repeater's running firmware. Select a delta built from that exact image, or a full update.")
      }
    }
  }

  static func validateBootloader(_ package: MotaContainer, reply: String, ready: Bool) throws {
    guard let fields = fields(#"^BL board=([0-9A-Fa-f]{8}) target=([0-9A-Fa-f]{8}) name=(\S+) crc=([0-9A-Fa-f]{8}) abi=(\d+) caps=([0-9A-Fa-f]{2}) \| staged:(ready|none) mid=(-|[0-9A-Fa-f]{8}) hash=(-|[0-9A-Fa-f]{16})$"#, in: reply.trimmingCharacters(in: .whitespacesAndNewlines)),
          fields[0].uppercased() == "239A0071", fields[1].uppercased() == "1150F50E",
          fields[2] == "TOWER_V2_OTA", let abi = Int(fields[4]), abi >= 3,
          fields[5] == "09" else {
      throw LoRaOTAError.message("Repeater needs an exact-board ABI-3+ SD self-update bootloader. Local provisioning may be required first.")
    }
    if ready {
      let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
      let hash = package.imageHash.prefix(8).map { String(format: "%02X", $0) }.joined()
      guard fields[6] == "ready", fields[7].uppercased() == mid, fields[8].uppercased() == hash else {
        throw LoRaOTAError.message("Repeater did not confirm the exact staged bootloader ID and hash. Installation must not proceed.")
      }
    }
  }
}
