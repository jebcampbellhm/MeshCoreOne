import Testing
@testable import MC1Services

struct OTAInstallCommandTests {
  let status = "OTA | this fw 62703F3B | download: ready to install 10/10 (100%) id=57CBECA2"
  let stats = "OTA | fw v1 id=12345678 | fetch done 10/10 100% id=57CBECA2 12s | af=off"
  let boot = "BL board=239A0071 target=1150F50E name=TOWER_V2_OTA crc=12345678 abi=3 caps=09 | staged:ready mid=57cbeca2 hash=0123456789abcdef"
  let none = "BL board=239A0071 target=1150F50E name=TOWER_V2_OTA crc=12345678 abi=3 caps=09 | staged:none mid=- hash=-"

  @Test func bootloaderUsesStagedIDAndHash() throws {
    #expect(try OTAInstallCommand.make(status: status, stats: stats, bootloaderStatus: boot)
      == "ota bootloader install 57CBECA2 0123456789ABCDEF")
  }

  @Test func firmwareUsesPlainInstall() throws {
    #expect(try OTAInstallCommand.make(status: status, stats: stats, bootloaderStatus: none) == "ota install")
  }

  @Test(arguments: ["incomplete", "wrong ID", "status changed", "missing hash", "boot not ready", "error", "zero blocks"])
  func refusesAmbiguousOrIncompleteState(mode: String) {
    let state = mode == "boot not ready" ? status.replacingOccurrences(of: "download:", with: "bootloader download:")
      : mode == "status changed" ? status.replacingOccurrences(of: "57CBECA2", with: "AAAAAAAA") : status
    let fetch = mode == "incomplete" ? stats.replacingOccurrences(of: "done", with: "dl")
      : mode == "zero blocks" ? stats.replacingOccurrences(of: "10/10", with: "0/0") : stats
    let reply = mode == "wrong ID" ? boot.replacingOccurrences(of: "57cbeca2", with: "AAAAAAAA")
      : mode == "missing hash" ? boot.replacingOccurrences(of: "0123456789abcdef", with: "0123")
      : mode == "boot not ready" ? none : mode == "error" ? "ERR unavailable" : boot
    #expect(throws: (any Error).self) {
      try OTAInstallCommand.make(status: state, stats: fetch, bootloaderStatus: reply)
    }
  }
}
