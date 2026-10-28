import Foundation

enum OTASpeed {
  static func savedValue(_ reply: String) throws -> String {
    guard let value = OTAPackageCompatibility.fields(#"^(?:> |OK )ota\.speed=([0-9]+(?:\.[0-9]+)?)x(?:\s|$)"#, in: reply)?.first,
          let number = Double(value), number.isFinite, (0.05...3).contains(number) else {
      throw LoRaOTAError.message("Device did not report a supported OTA speed. \(reply)")
    }
    return value
  }

  static func value(_ speed: Double) throws -> String {
    guard speed.isFinite, (0.05...3).contains(speed) else {
      throw LoRaOTAError.message("OTA speed must be between 0.05× and 3×.")
    }
    return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), speed)
  }

  static func confirm(_ reply: String, expected: String) throws {
    guard reply.hasPrefix("OK "), try Double(savedValue(reply)) == Double(expected) else {
      throw LoRaOTAError.message("Device did not confirm the requested OTA speed. \(reply)")
    }
  }
}
