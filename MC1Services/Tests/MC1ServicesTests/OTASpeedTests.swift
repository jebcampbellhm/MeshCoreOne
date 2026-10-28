import Testing
@testable import MC1Services

struct OTASpeedTests {
  @Test func readsSavedSpeedRatherThanAdaptivePacketPace() throws {
    #expect(try OTASpeed.savedValue("> ota.speed=0.123456x packet=0.25x") == "0.123456")
    #expect(try OTASpeed.value(2) == "2.000000")
    try OTASpeed.confirm("OK ota.speed=2x (saved) packet=0.25x", expected: "2.000000")
  }

  @Test(arguments: ["ERR unavailable", "> ota.speed=0x", "> ota.speed=4x", "> ota.speed=nanx", "> ota.speed=2xgarbage"])
  func refusesUnrestorableSpeed(reply: String) {
    #expect(throws: (any Error).self) { try OTASpeed.savedValue(reply) }
  }

  @Test func rejectsWrongOrUnacknowledgedWrite() {
    #expect(throws: (any Error).self) { try OTASpeed.confirm("OK ota.speed=1x (saved)", expected: "2") }
    #expect(throws: (any Error).self) { try OTASpeed.confirm("> ota.speed=2x", expected: "2") }
    #expect(throws: (any Error).self) { try OTASpeed.value(.nan) }
  }
}
