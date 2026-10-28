import Foundation
import Testing
import MeshCore
import MeshCoreTestSupport
@testable import MC1Services

private actor DistributionHarness {
  var calls: [(UUID?, String)] = []
  var settings: [String: String] = [:]
  var mode = "success"
  var offered = "folder=off serving=0:"
  var seeded = 0
  var legacy: UUID?
  func setLegacy(_ id: UUID) { legacy = id }
  let directory: URL
  init(directory: URL, mode: String = "success") { self.directory = directory; self.mode = mode }
  func key(_ node: UUID?, _ field: String) -> String { "\(node?.uuidString ?? "local"):\(field)" }
  func command(_ node: UUID?, _ command: String) throws -> String {
    calls.append((node, command))
    func value(_ field: String, _ fallback: String) -> String { settings[key(node, field)] ?? fallback }
    if let legacy, node == legacy {
      if command.contains("radio2") || command.contains("radioat2") { throw LoRaOTAError.message("Unsupported secondary radio") }
      if value("primary", "off") != "off" {
        guard settings[key(nil, "route")] == "both", settings[key(nil, "radio")] != nil,
              settings[key(nil, "radio")] != "off" else { throw RemoteNodeError.timeout }
      }
    }
    if command.hasPrefix("get tx.user key:") { return "> tx.user \"Destination\" key:030303030303 \(value("route", "auto")); active=radio" }
    if command == "tempradio" { return "> " + value("primary", "off") }
    if command == "get radio2.status" { return value("radio", "off") == "off" ? "> off; RX=0,0" : "> rxtx; RX=0,0" }
    if command == "get radio2" { return mode == "busy radio" ? "> 915,250,5,5,rxtx,64" : "> off (manual)" }
    if command == "get radioat2" || command == "get tempradioat2" { return "> slots: " }
    if command == "get tempradio2" { return "> " + value("radio", "off") }
    if command == "get radio2.cross" { return "> " + value("cross", "auto") }
    if command == "ota speed" { return "> ota.speed=\(value("speed", "1"))x packet=0.25x" }
    if command == "ota config" { return "ota config: cache=off/0 autofetch=off autoinstall=off hops=\(value("hops", "3"))" }
    if command == "ota status" { return "OTA | no download" }
    if command == "ota cache" { return mode == "no archive" ? "ERR this target has no SD-backed OTA archive" : "SD OTA archive: capture=\(value("cache", "off")) cached=1, idle" }
    if command == "ota folder" { if mode == "offline" { throw RemoteNodeError.timeout }; return offered }
    // A durable recovery entry must exist before the first write reaches firmware.
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("job.json").path))
    if command.hasPrefix("set tx.user key:") { settings[key(node, "route")] = String(command.split(separator: " ").last!) }
    if command.hasPrefix("tempradio ") {
      settings[key(node, "primary")] = command.dropFirst(10).split(separator: ",").dropLast().joined(separator: ",")
      if mode == "lost primary ACK" { throw RemoteNodeError.timeout }
    }
    if command == "normalradio" {
      if mode == "restore failure" { throw RemoteNodeError.timeout }
      settings[key(node, "primary")] = "off"
    }
    if command.hasPrefix("ota speed ") { settings[key(node, "speed")] = String(command.dropFirst(10)) }
    if command.hasPrefix("ota config hops ") { settings[key(node, "hops")] = String(command.dropFirst(16)) }
    if command.hasPrefix("set radio2.cross ") { settings[key(node, "cross")] = String(command.dropFirst(17)) }
    if command.hasPrefix("ota cache ") { settings[key(node, "cache")] = String(command.dropFirst(10)) }
    if command.hasPrefix("set tempradio2 ") {
      let tuple = String(command.dropFirst(15))
      settings[key(node, "radio")] = tuple == "off" ? "off" : tuple.split(separator: ",").dropLast().joined(separator: ",") + ",64"
      if mode == "lost radio ACK", tuple != "off" { throw RemoteNodeError.timeout }
    }
    return "OK"
  }
  func setMode(_ value: String) { mode = value }
  func setOffered(_ value: String) { offered = value }
  func start(_ packages: [MotaContainer]) { seeded = packages.count }
  func stop() { seeded = 0 }
  func externallyChangeSpeed(_ node: UUID) { settings[key(node, "speed")] = "0.5" }
  func operations() -> OTADistribution.Operations {
    .init(login: { _ in }, command: { try await self.command($0, $1) },
      start: { await self.start($0) }, stop: { await self.stop() }, pause: {})
  }
}

struct OTADistributionTests {
  func nodes(_ count: Int, radioID: UUID) -> [OTADistributionNode] {
    (0..<count).map { OTADistributionNode(session: .testSession(radioID: radioID,
      publicKey: Data(repeating: UInt8($0 + 1), count: 32), name: "Node \($0)", role: .repeater)) }
  }
  @Test(arguments: ["success", "lost radio ACK", "busy radio", "no archive"])
  func preflightRecoveryAndExactServing(mode: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = DistributionHarness(directory: directory, mode: mode)
    let ops = await harness.operations()
    let engine = try OTADistribution(operations: ops, directory: directory)
    let radioID = UUID(); let route = nodes(3, radioID: radioID)
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    var failed = false
    do { try await engine.prepare(radioID: radioID, nodes: route, containers: [package], names: ["full.mota"],
      frequency: 909.5, bandwidth: 500, sf: 5, minutes: 120, speed: 2) }
    catch { failed = true }
    #expect(failed == (mode != "success"))
    let calls = await harness.calls
    if mode == "busy radio" || mode == "no archive" {
      #expect(!calls.contains { $0.1.hasPrefix("set ") || $0.1.hasPrefix("ota speed ") })
      #expect(await engine.snapshot() == nil)
    } else if mode == "lost radio ACK" {
      #expect(calls.filter { $0.1.hasPrefix("set tempradio2 ") && $0.1 != "set tempradio2 off" }.count == 1)
      #expect(await engine.snapshot()?.changes.isEmpty == true)
    } else {
      let radios = calls.filter { $0.1.hasPrefix("set tempradio2 ") }.map(\.0)
      #expect(radios == route.reversed().map { Optional($0.id) } + [nil])
      try await engine.seed(); #expect(await harness.seeded == 1)
      let snapshot = try #require(await engine.snapshot())
      let meta = snapshot.packages[0]
      await harness.setOffered("folder=off serving=1: \(meta.id)/\(meta.target)")
      try await engine.refresh()
      #expect(await engine.snapshot()?.hasCompleteArchive == true)
      await engine.stopSeeding(); #expect(await harness.seeded == 0)
      // A restarted controller can recover without firmware bytes or passwords in its journal.
      let restarted = try OTADistribution(operations: ops, directory: directory)
      await restarted.restore()
      #expect(await restarted.snapshot()?.changes.isEmpty == true)
      try await restarted.dismissFinishedJob()
      #expect(await restarted.snapshot() == nil)
    }
  }
  @Test(arguments: ["success", "lost primary ACK", "restore failure"])
  func mixedRadioRecovery(mode: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = DistributionHarness(directory: directory, mode: mode)
    let radioID = UUID(); let route = nodes(3, radioID: radioID)
    let destination = route[2].id
    await harness.setLegacy(destination)
    let ops = await harness.operations()
    let engine = try OTADistribution(operations: ops, directory: directory)
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    try await engine.prepare(radioID: radioID, nodes: route, containers: [package], names: ["full"],
      frequency: 909.5, bandwidth: 500, sf: 5, minutes: 120, speed: 2, destinationUsesPrimary: true)
    let calls = await harness.calls
    #expect(calls.filter { $0.1.hasPrefix("set tempradio2 ") }.map(\.0) == [route[1].id, route[0].id, nil])
    #expect(!calls.contains { $0.0 == destination && $0.1.contains("radio2") })
    #expect(calls.filter { $0.1.hasPrefix("tempradio ") }.count == 1)
    let localSwitch = try #require(calls.firstIndex { $0.0 == nil && $0.1.hasPrefix("set tempradio2 ") })
    let targetSwitch = try #require(calls.firstIndex { $0.1.hasPrefix("tempradio ") })
    #expect(localSwitch < targetSwitch)
    let reopened = try OTADistribution(operations: ops, directory: directory)
    #expect(await reopened.snapshot()?.legacyDestinationID == destination)
    await reopened.restore()
    if mode == "restore failure" {
      #expect(await reopened.snapshot()?.changes.contains { $0.read == "tempradio" } == true)
      #expect(await reopened.snapshot()?.changes.filter { $0.read == "get tempradio2" }.count == 3)
      #expect(!(await harness.calls).contains { $0.1 == "set tempradio2 off" })
      await harness.setMode("success")
      await reopened.restore()
    }
    #expect(await reopened.snapshot()?.changes.isEmpty == true)
    let restoredCalls = await harness.calls
    let targetRestore = try #require(restoredCalls.lastIndex { $0.1 == "normalradio" })
    let relayRestore = try #require(restoredCalls.firstIndex { $0.1 == "set tempradio2 off" })
    #expect(targetRestore < relayRestore)
    #expect(try await harness.command(nil, "get tx.user key:test").contains(" auto;"))
  }

  @Test func primaryRadioStateParsing() throws {
    #expect(try OTADistributionParsing.primaryRadio("> off") == "off")
    #expect(try OTADistributionParsing.primaryRadio("tempradio inactive") == "off")
    #expect(try OTADistributionParsing.primaryRadio("> 909.500,500.000,5,5,64") == "909.500,500.000,5,5")
    #expect(throws: (any Error).self) { try OTADistributionParsing.primaryRadio("> pending") }
    #expect(throws: (any Error).self) { try OTADistributionParsing.primaryRadio("ERR unknown command") }
  }

  @Test func catalogNeverConfusesSelfWrongTargetOrTruncatedIDWithArchive() {
    let packages = [OTADistributionPackage(id: "12345678", name: "x", target: "AABBCCDD")]
    #expect(OTADistributionParsing.served("folder=off serving=1: 12345678/AABBCCDD", packages: packages) == ["12345678"])
    for reply in ["folder=off serving=1: *12345678/AABBCCDD", "folder=off serving=1: 12345678/00000000", "folder=off serving=1: 12345678/AABB", "folder=on serving=1: 12345678/AABBCCDD"] {
      #expect(OTADistributionParsing.served(reply, packages: packages).isEmpty)
    }
  }
  @Test func externalChangesArePreservedAndStaleReadinessIsCleared() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = DistributionHarness(directory: directory)
    let engine = try OTADistribution(operations: await harness.operations(), directory: directory)
    let radioID = UUID(); let route = nodes(1, radioID: radioID)
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    try await engine.prepare(radioID: radioID, nodes: route, containers: [package], names: ["x"],
      frequency: 909.5, bandwidth: 500, sf: 5, minutes: 120, speed: 2)
    let snapshot = try #require(await engine.snapshot())
    let meta = snapshot.packages[0]
    await harness.setOffered("folder=off serving=1: \(meta.id)/\(meta.target)")
    try await engine.refresh()
    #expect(await engine.snapshot()?.hasCompleteArchive == true)
    await harness.setMode("offline")
    try await engine.refresh()
    #expect(await engine.snapshot()?.hasCompleteArchive == false)
    await harness.setMode("success")
    await harness.externallyChangeSpeed(route[0].id)
    await engine.restore()
    #expect(await engine.snapshot()?.changes.count == 1)
    #expect(await engine.snapshot()?.changes.first?.restore == "ota speed 1")
    #expect(await engine.snapshot()?.message.contains("changed externally") == true)
  }

  @Test func refusesMoreThanTwoRelays() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = DistributionHarness(directory: directory)
    let engine = try OTADistribution(operations: await harness.operations(), directory: directory)
    let radioID = UUID()
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    await #expect(throws: (any Error).self) {
      try await engine.prepare(radioID: radioID, nodes: nodes(4, radioID: radioID), containers: [package], names: ["x"],
        frequency: 909.5, bandwidth: 500, sf: 5, minutes: 120, speed: 2)
    }
    #expect(await harness.calls.isEmpty)
  }
}
