import Foundation
import MeshCore
import Testing
@testable import MC1Services

private actor OTAHarness {
  var calls: [String] = []
  let mid: String
  let mode: String
  var pulled = false
  init(mid: String, mode: String) { self.mid = mid; self.mode = mode }
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
      let downloadID = mode == "wrong ID" ? "12345678" : mid
      let state = mode == "rejected" ? "failed:signature" : "done"
      return "OTA | fw v1 id=\(mid) | fetch \(state) 1/1 100% id=\(downloadID) 1s | af=off"
    }
    if command == "ota storage" { return mode == "no SD" ? "SD unavailable; internal delta staging" : "OTA storage: SD staging; capacity=999K" }
    if command == "ota config" { return "ota config: autoinstall=\(mode == "auto install" ? "trusted" : "off")" }
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
