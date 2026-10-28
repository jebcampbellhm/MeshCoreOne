import Foundation

/// Builds a copyable command only from a complete, live receiver download.
enum OTAInstallCommand {
  static func make(status: String, stats: String, bootloaderStatus: String) throws -> String {
    guard let fetch = stats.components(separatedBy: " | ").first(where: { $0.hasPrefix("fetch ") }),
          let fields = OTAPackageCompatibility.fields(#"^fetch done (\d+)/(\d+) 100% id=([0-9A-Fa-f]{8})(?:\s|$)"#, in: fetch),
          let count = Int(fields[0]), count > 0, count == Int(fields[1]),
          status.contains("download: ready to install") else {
      throw LoRaOTAError.message("No completed download is ready to install. \(status)")
    }
    let mid = fields[2].uppercased()
    if let statusID = OTAPackageCompatibility.fields(#"\bdownload:.*?\bid=([0-9A-Fa-f]{8})(?:\s|$)"#, in: status)?.first,
       statusID.uppercased() != mid {
      throw LoRaOTAError.message("The download changed while reading status. Refresh before installing.")
    }
    if let staged = OTAPackageCompatibility.fields(#"\| staged:ready mid=([0-9A-Fa-f]{8}) hash=([0-9A-Fa-f]{16})$"#, in: bootloaderStatus.trimmingCharacters(in: .whitespacesAndNewlines)) {
      guard staged[0].uppercased() == mid else {
        throw LoRaOTAError.message("Download and staged bootloader IDs differ. Refresh status before installing.")
      }
      return "ota bootloader install \(mid) \(staged[1].uppercased())"
    }
    guard !status.contains("bootloader download:"),
          bootloaderStatus.hasPrefix("BL board="),
          bootloaderStatus.hasSuffix("| staged:none mid=- hash=-") else {
      throw LoRaOTAError.message("The repeater has not confirmed a staged bootloader ID/hash. \(bootloaderStatus)")
    }
    return "ota install"
  }
}
