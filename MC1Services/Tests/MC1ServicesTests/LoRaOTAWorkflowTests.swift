import Foundation
import MeshCore
import MeshCoreTestSupport
import Testing
@testable import MC1Services

private actor OTAHarness {
  var calls: [String] = []
  let mid: String
  let mode: String
  var pulled = false
  let package: MotaContainer?
  var statusReads = 0
  init(mid: String, mode: String, package: MotaContainer? = nil) { self.mid = mid; self.mode = mode; self.package = package }
  func login() { calls.append("login") }
  func local(_ command: String) -> String { calls.append("local " + command); return "OK" }
  func start() throws {
    calls.append("seed")
    if mode == "source failure" { throw LoRaOTAError.message("Source unavailable") }
  }
  func stop() { calls.append("stop") }
  func remote(_ command: String) throws -> String {
    calls.append(command)
    if command == "ota status" {
      return pulled ? "OTA | download: ready to install 1/1 (100%) id=\(mid) 1s"
        : "OTA | hw=Heltec_tower_v2 | target:0A9DBBF0 | maxblk:1024 | no download"
    }
    if command == "ota stats" {
      statusReads += 1
      if mode == "read timeout", statusReads == 1 { throw RemoteNodeError.timeout }
      let downloadID = mode == "wrong ID" ? "12345678" : mid
      let state = mode == "rejected" ? "failed:signature" : "done"
      return "OTA | fw v1 id=\(mid) | fetch \(state) 1/1 100% id=\(downloadID) 1s | af=off"
    }
    if command == "ota self" {
      let base = mode == "wrong base" ? "0000000000000000" : package?.baseHash.map { String(format: "%02X", $0) }.joined() ?? "0000000000000000"
      return "self body=41 image=97 base_hash=\(base) | maxblk:1024 | bootloader: SD apply OK (abi=3 codecs=0x5)"
    }
    if command == "ota bootloader status" {
      let hash = mode == "wrong staged hash" ? "0000000000000000" : package?.imageHash.prefix(8).map { String(format: "%02X", $0) }.joined() ?? "0000000000000000"
      let caps = mode == "wrong boot storage" ? "0A" : "09"
      return "BL board=239A0071 target=1150F50E name=TOWER_V2_OTA crc=12345678 abi=3 caps=\(caps) | staged:\(pulled ? "ready" : "none") mid=\(pulled ? mid : "-") hash=\(pulled ? hash : "-")"
    }
    if command == "ota storage" { return mode == "no SD" ? "SD unavailable; internal delta staging" : "OTA storage: SD staging; capacity=999K" }
    if command == "ota config" { return "ota config: autofetch=off autoinstall=\(mode == "auto install" ? "trusted" : "off")" }
    if command.hasPrefix("tempradio"), mode == "lost ACK" { throw RemoteNodeError.timeout }
    if command == "ota ls 1" { return "Updates 1/2: 12345678" }
    if command == "ota ls 2" { return "Updates 2/2: \(mid)" }
    if command.hasPrefix("ota pull") {
      pulled = true
      if mode == "lost ACK" { throw RemoteNodeError.timeout }
    }
    return "OK"
  }
}

struct LoRaOTAWorkflowTests {
  @Test(arguments: ["full", "delta", "bootloader"])
  func packageFamiliesReachStagedState(name: String) async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data(name))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: "read timeout", package: package)
    try await run(package, harness: harness)
    let calls = await harness.calls
    #expect(calls.contains("ota self"))
    #expect(calls.filter { $0 == "ota pull \(mid) flash" }.count == 1)
    #expect(calls.filter { $0 == "ota stats" }.count == 2)
    #expect(!calls.contains(where: { $0.contains("install ") }))
    if name == "bootloader" { #expect(calls.filter { $0 == "ota bootloader status" }.count == 2) }
  }

  @Test(arguments: ["wrong base", "wrong boot storage", "wrong staged hash"])
  func rejectsPackageSpecificMismatch(mode: String) async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data(mode == "wrong base" ? "delta" : "bootloader"))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: mode, package: package)
    await #expect(throws: (any Error).self) { try await run(package, harness: harness) }
    let calls = await harness.calls
    if mode != "wrong staged hash" { #expect(!calls.contains("seed")) }
    #expect(!calls.contains(where: { $0.contains("install ") }))
  }

  private func run(_ package: MotaContainer, harness: OTAHarness) async throws {
    let workflow = LoRaOTAWorkflow(operations: .init(
      login: { await harness.login() }, remote: { try await harness.remote($0) },
      local: { await harness.local($0) }, startSource: { _ in try await harness.start() },
      stopSource: { await harness.stop() }, pause: {}))
    let radio = try OTATemporaryRadio(frequencyMHz: 915, bandwidthKHz: 250, spreadingFactor: 5, codingRate: 5, minutes: 120)
    try await workflow.run(container: package, radio: radio) { _ in }
  }

  @Test(arguments: ["success", "lost ACK", "no SD", "auto install", "source failure", "wrong ID", "rejected"])
  func transferOrderAndFailureCleanup(mode: String) async throws {
    let container = try MotaContainer(data: MotaReferenceFixture.container)
    let mid = container.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: mode)
    let radio = try OTATemporaryRadio(frequencyMHz: 915, bandwidthKHz: 250, spreadingFactor: 5, codingRate: 5, minutes: 120)
    let workflow = LoRaOTAWorkflow(operations: .init(
      login: { await harness.login() }, remote: { try await harness.remote($0) },
      local: { await harness.local($0) }, startSource: { _ in try await harness.start() },
      stopSource: { await harness.stop() }, pause: {}))
    var failed = false
    do { try await workflow.run(container: container, radio: radio) { _ in } }
    catch { failed = true }
    let calls = await harness.calls
    #expect(failed == !["success", "lost ACK"].contains(mode))
    #expect(!calls.contains(where: { $0.hasPrefix("ota install") }))
    if mode == "no SD" || mode == "auto install" {
      #expect(!calls.contains(radio.command))
      #expect(!calls.contains("seed"))
    } else {
      #expect(calls.firstIndex(of: radio.command)! < calls.firstIndex(of: "local " + radio.command)!)
      #expect(calls.firstIndex(of: "local " + radio.command)! < calls.firstIndex(of: "seed")!)
      #expect(Array(calls.suffix(2)) == ["normalradio", "local normalradio"])
      if mode != "source failure" {
        #expect(calls.filter { $0 == "login" }.count == 2)
        #expect(calls.filter { $0.hasPrefix("ota pull") }.count == 1)
        #expect(calls.firstIndex(of: "seed")! < calls.firstIndex(of: "ota pull \(mid) flash")!)
        #expect(calls.contains("stop"))
      } else { #expect(!calls.contains(where: { $0.hasPrefix("ota pull") })) }
    }
  }

  @Test func rejectsInvalidRadio() {
    #expect(throws: (any Error).self) {
      try OTATemporaryRadio(frequencyMHz: .nan, bandwidthKHz: 250, spreadingFactor: 5, codingRate: 5, minutes: 120)
    }
    #expect(throws: (any Error).self) {
      try OTATemporaryRadio(frequencyMHz: 915, bandwidthKHz: 123, spreadingFactor: 5, codingRate: 5, minutes: 0)
    }
  }

  @Test func cancellationStillStopsSourceAndRestoresRadios() async throws {
    let container = try MotaContainer(data: MotaReferenceFixture.container)
    let harness = OTAHarness(mid: "unused", mode: "success")
    let radio = try OTATemporaryRadio(frequencyMHz: 915, bandwidthKHz: 250, spreadingFactor: 5, codingRate: 5, minutes: 120)
    let workflow = LoRaOTAWorkflow(operations: .init(
      login: { await harness.login() }, remote: { try await harness.remote($0) },
      local: { await harness.local($0) }, startSource: { _ in try await harness.start() },
      stopSource: { await harness.stop() }, pause: {}))
    let task = Task {
      do {
        try await workflow.run(container: container, radio: radio) { status in
          if status == "Logging into repeater on temporary radio" {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
        Issue.record("Cancelled transfer unexpectedly succeeded")
      } catch { }
    }
    await task.value
    let calls = await harness.calls
    #expect(Array(calls.suffix(3)) == ["stop", "normalradio", "local normalradio"])
    #expect(!calls.contains(where: { $0.hasPrefix("ota pull") }))
  }
}
