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
  var cleared = false
  var cachePaused = false
  init(mid: String, mode: String, package: MotaContainer? = nil) { self.mid = mid; self.mode = mode; self.package = package }
  func login() throws {
    calls.append("login")
    if mode == "login always busy" || (mode == "login busy" && calls.filter { $0 == "login" }.count == 1) {
      throw MeshCoreError.deviceError(code: 0x04)
    }
    if mode == "login denied" { throw MeshCoreError.deviceError(code: 0x01) }
  }
  func pause() { calls.append("pause") }
  func local(_ command: String) throws -> String {
    calls.append("local " + command)
    if command == "ota speed" { return "> ota.speed=\(mode.hasPrefix("speed") ? "0.5" : "2")x packet=0.25x" }
    if command.hasPrefix("ota speed ") {
      if mode == "speed local timeout", command == "ota speed 2.000000" { throw RemoteNodeError.timeout }
      return "OK ota.speed=\(command.split(separator: " ").last!)x (saved) packet=1x"
    }
    return "OK"
  }
  func start() throws {
    calls.append("seed")
    if mode == "source failure" { throw LoRaOTAError.message("Source unavailable") }
  }
  func stop() { calls.append("stop") }
  func remote(_ command: String) throws -> String {
    calls.append(command)
    if command == "ota speed" {
      if mode == "speed unreadable" { return "ERR unsupported" }
      return "> ota.speed=\(mode.hasPrefix("speed") ? "1" : "2")x packet=0.25x"
    }
    if command.hasPrefix("ota speed ") {
      if mode == "speed remote timeout", command == "ota speed 2.000000" { throw RemoteNodeError.timeout }
      if mode == "speed restore failed", command == "ota speed 1" { return "ERR save failed" }
      return "OK ota.speed=\(command.split(separator: " ").last!)x (saved) packet=1x"
    }
    if command == "ota cache off" {
      cachePaused = true
      if mode == "archive lost ACK" { throw RemoteNodeError.timeout }
      return "OK SD OTA archive capture off"
    }
    if command == "ota cache" { return "SD OTA archive: capture=\(cachePaused ? "off" : "on") cached=0, idle" }
    if command == "ota cache on" { cachePaused = false; return "OK SD OTA archive capture on" }
    if command == "ota status" {
      if mode.hasPrefix("archive"), calls.contains("seed"), !cachePaused {
        return "OTA | download: starting 0/0 (0%) id=A99EF3E6"
      }
      let backend = mode == "fixed SD wrong backend" ? "internal" : "SD"
      if mode.hasPrefix("existing"), !cleared {
        return "OTA | hw=Heltec_tower_v2 | target:0A9DBBF0 | maxblk:1024 | bl:SD | download: fetching 1/10 (10%) id=12345678"
      }
      return pulled ? "OTA | download: ready to install 1/1 (100%) id=\(mid) 1s"
        : "OTA | hw=Heltec_tower_v2 | target:0A9DBBF0 | maxblk:1024 | bl:\(backend) | no download"
    }
    if command == "ota cancel" {
      cleared = mode != "existing remains"
      if mode == "existing clear timeout" { throw RemoteNodeError.timeout }
      if mode == "existing clear rejected" { return "ERR dropped live session, but persistent OTA slot invalidation failed" }
      return "OK dropped session; OTA receive slot confirmed clear"
    }
    if command == "ota stats" {
      statusReads += 1
      if mode == "read timeout", statusReads == 1 { throw RemoteNodeError.timeout }
      if mode == "read busy", statusReads == 1 { throw RemoteNodeError.sessionError(.deviceError(code: 0x04)) }
      let downloadID = mode == "wrong ID" ? "12345678" : mid
      let state = mode == "rejected" ? "failed:signature" : "done"
      return "OTA | fw v1 id=\(mid) | fetch \(state) 1/1 100% id=\(downloadID) 1s | af=off"
    }
    if command == "ota self" {
      if mode == "fixed SD no apply" { return "self body=41 image=97 base_hash=0000000000000000 | bootloader: NO SD apply (abi=3 codecs=0x5)" }
      let base = mode == "wrong base" ? "0000000000000000" : package?.baseHash.map { String(format: "%02X", $0) }.joined() ?? "0000000000000000"
      return "self body=41 image=97 base_hash=\(base) | maxblk:1024 | bootloader: SD apply OK (abi=3 codecs=0x5)"
    }
    if command == "ota bootloader status" {
      let hash = mode == "wrong staged hash" ? "0000000000000000" : package?.imageHash.prefix(8).map { String(format: "%02X", $0) }.joined() ?? "0000000000000000"
      let caps = mode == "wrong boot storage" ? "0A" : "09"
      return "BL board=239A0071 target=1150F50E name=TOWER_V2_OTA crc=12345678 abi=3 caps=\(caps) | staged:\(pulled ? "ready" : "none") mid=\(pulled ? mid : "-") hash=\(pulled ? hash : "-")"
    }
    if command == "ota storage" {
      if mode.hasPrefix("fixed SD") { return "ERR this build does not use a QSPI OTA store" }
      return mode.contains("no SD") ? "SD unavailable; internal delta staging" : "OTA storage: SD staging; capacity=999K"
    }
    if command == "ota config" { return "ota config: cache=\(mode.hasPrefix("archive") ? "on/0" : "off/0") autofetch=off autoinstall=\(mode.contains("auto install") ? "trusted" : "off")" }
    if command.hasPrefix("tempradio"), mode == "lost ACK" { throw RemoteNodeError.timeout }
    if command == "ota ls 1" { return "Updates 1/2: 12345678" }
    if command == "ota ls 2" { return "Updates 2/2: \(mid)" }
    if command.hasPrefix("ota pull") {
      if mode == "pull busy" || mode == "archive pull busy" || mode == "speed pull failed" { throw MeshCoreError.deviceError(code: 0x04) }
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
    let command = try await run(package, harness: harness)
    let hash = package.imageHash.prefix(8).map { String(format: "%02X", $0) }.joined()
    #expect(command == (name == "bootloader" ? "ota bootloader install \(mid) \(hash)" : "ota install"))
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

  @discardableResult
  private func run(_ package: MotaContainer, harness: OTAHarness, clearExistingDownload: Bool = false) async throws -> String {
    let workflow = LoRaOTAWorkflow(operations: .init(
      login: { try await harness.login() }, remote: { try await harness.remote($0) },
      local: { try await harness.local($0) }, startSource: { _ in try await harness.start() },
      stopSource: { await harness.stop() }, pause: { await harness.pause() }))
    let radio = try OTATemporaryRadio(frequencyMHz: 915, bandwidthKHz: 250, spreadingFactor: 5, codingRate: 5, minutes: 120)
    return try await workflow.run(container: package, radio: radio, clearExistingDownload: clearExistingDownload) { _ in }
  }

  @Test(arguments: ["full", "delta", "bootloader"])
  func fixedSDStorageDiagnosticDoesNotRequireQSPI(name: String) async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data(name))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: "fixed SD", package: package)
    try await run(package, harness: harness)
    #expect(await harness.calls.contains("ota pull \(mid) flash"))
  }

  @Test(arguments: ["fixed SD wrong backend", "fixed SD no apply"])
  func unsupportedStorageDiagnosticAloneDoesNotProveSD(mode: String) async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    let harness = OTAHarness(mid: "unused", mode: mode, package: package)
    await #expect(throws: (any Error).self) { try await run(package, harness: harness) }
    #expect(await !harness.calls.contains("seed"))
  }

  @Test func existingDownloadIsPreservedByDefault() async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    let harness = OTAHarness(mid: "unused", mode: "existing success", package: package)
    await #expect(throws: (any Error).self) { try await run(package, harness: harness) }
    let calls = await harness.calls
    #expect(!calls.contains("ota cancel"))
    #expect(!calls.contains("seed"))
  }

  @Test(arguments: ["existing success", "existing clear timeout", "existing clear rejected", "existing remains", "existing no SD", "existing auto install"])
  func clearingMustBeConfirmedBeforeRadioChangesOrPull(mode: String) async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: mode, package: package)
    var failed = false
    do { try await run(package, harness: harness, clearExistingDownload: true) }
    catch { failed = true }
    #expect(failed == (mode != "existing success"))
    let calls = await harness.calls
    let failsPreflight = mode == "existing no SD" || mode == "existing auto install"
    #expect(calls.filter { $0 == "ota cancel" }.count == (failsPreflight ? 0 : 1))
    if mode == "existing success" {
      let cancel = try #require(calls.firstIndex(of: "ota cancel"))
      #expect(calls[cancel + 1] == "ota status")
      #expect(cancel < (try #require(calls.firstIndex { $0.hasPrefix("tempradio ") })))
      #expect(calls.filter { $0.hasPrefix("ota pull ") }.count == 1)
    } else {
      #expect(!calls.contains { $0.hasPrefix("tempradio ") || $0.hasPrefix("ota pull ") || $0 == "seed" })
    }
  }

  @Test func clearOptionDoesNotCancelAnIdleRepeater() async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: "success", package: package)
    try await run(package, harness: harness, clearExistingDownload: true)
    #expect(await !harness.calls.contains("ota cancel"))
  }

  @Test func transferFrequencyCommandUses909Point5MHz() throws {
    let radio = try OTATemporaryRadio(frequencyMHz: 909.5, bandwidthKHz: 250, spreadingFactor: 5, codingRate: 5, minutes: 120)
    #expect(radio.command == "tempradio 909.500,250.00,5,5,120")
  }

  @Test(arguments: ["success", "lost ACK", "no SD", "auto install", "source failure", "wrong ID", "rejected"])
  func transferOrderAndFailureCleanup(mode: String) async throws {
    let container = try MotaContainer(data: MotaReferenceFixture.container)
    let mid = container.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: mode)
    let radio = try OTATemporaryRadio(frequencyMHz: 915, bandwidthKHz: 250, spreadingFactor: 5, codingRate: 5, minutes: 120)
    let workflow = LoRaOTAWorkflow(operations: .init(
      login: { try await harness.login() }, remote: { try await harness.remote($0) },
      local: { try await harness.local($0) }, startSource: { _ in try await harness.start() },
      stopSource: { await harness.stop() }, pause: { await harness.pause() }))
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
        #expect(calls.filter { $0 == "login" }.count == 1)
        #expect(calls.filter { $0.hasPrefix("ota pull") }.count == 1)
        #expect(calls.firstIndex(of: "seed")! < calls.firstIndex(of: "ota pull \(mid) flash")!)
        #expect(calls.contains("stop"))
      } else { #expect(!calls.contains(where: { $0.hasPrefix("ota pull") })) }
    }
  }

  @Test(arguments: ["login busy", "login always busy", "login denied", "read busy", "pull busy"])
  func busyRetriesAreBoundedAndDoNotReplayMutations(mode: String) async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: mode, package: package)
    var failed = false
    do { try await run(package, harness: harness) } catch { failed = true }
    #expect(failed == ["login always busy", "login denied", "pull busy"].contains(mode))
    let calls = await harness.calls
    let expectedLogins = mode == "login always busy" ? 4 : mode == "login busy" ? 2 : 1
    #expect(calls.filter { $0 == "login" }.count == expectedLogins)
    if mode == "login always busy" || mode == "login denied" {
      #expect(!calls.contains("seed"))
      #expect(calls.filter { $0 == "pause" }.count == (mode == "login always busy" ? 3 : 0))
    } else {
      let seed = try #require(calls.firstIndex(of: "seed"))
      #expect(calls[seed + 1] == "pause")
      #expect(calls.filter { $0.hasPrefix("ota pull ") }.count == 1)
      if mode == "read busy" { #expect(calls.filter { $0 == "ota stats" }.count == 2) }
    }
  }

  @Test(arguments: ["archive success", "archive lost ACK", "archive pull busy"])
  func archiveCapturePausesAndRestoresEvenOnFailure(mode: String) async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data("bootloader"))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: mode, package: package)
    var failed = false
    do { try await run(package, harness: harness) } catch { failed = true }
    #expect(failed == (mode != "archive success"))
    let calls = await harness.calls
    #expect(calls.filter { $0 == "ota cache off" }.count == 1)
    #expect(calls.filter { $0 == "ota cache on" }.count == 1)
    #expect(await !harness.cachePaused)
    if mode == "archive lost ACK" {
      #expect(!calls.contains("seed"))
    } else {
      #expect(calls.firstIndex(of: "ota cache off")! < calls.firstIndex(of: "seed")!)
      #expect(calls.firstIndex(of: "ota cache on")! < calls.firstIndex(of: "normalradio")!)
      #expect(calls.filter { $0.hasPrefix("ota pull ") }.count == 1)
    }
  }

  @Test(arguments: ["speed success", "speed remote timeout", "speed local timeout", "speed unreadable", "speed pull failed"])
  func temporarySpeedRestoresEachOriginalEvenAfterLostAcknowledgement(mode: String) async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: mode, package: package)
    var failed = false
    do { try await run(package, harness: harness) } catch { failed = true }
    #expect(failed == (mode != "speed success"))
    let calls = await harness.calls
    if mode == "speed unreadable" {
      #expect(!calls.contains { $0.hasPrefix("ota speed ") || $0.hasPrefix("local ota speed ") })
      #expect(!calls.contains("seed"))
    } else {
      #expect(calls.filter { $0 == "ota speed 2.000000" }.count == 1)
      #expect(calls.filter { $0 == "ota speed 1" }.count == 1)
      #expect(calls.filter { $0 == "local ota speed 0.5" }.count == (mode == "speed remote timeout" ? 0 : 1))
      if calls.contains("normalradio") {
        #expect(calls.firstIndex(of: "ota speed 1")! < calls.firstIndex(of: "normalradio")!)
      }
    }
  }

  @Test func unconfirmedSpeedRestorationReportsRecoveryCommand() async throws {
    let package = try MotaContainer(data: MotaPackageFixtures.data("full"))
    let mid = package.manifestID.map { String(format: "%02X", $0) }.joined()
    let harness = OTAHarness(mid: mid, mode: "speed restore failed", package: package)
    let progress = OTAProgressRecorder()
    let workflow = LoRaOTAWorkflow(operations: .init(
      login: { try await harness.login() }, remote: { try await harness.remote($0) },
      local: { try await harness.local($0) }, startSource: { _ in try await harness.start() },
      stopSource: { await harness.stop() }, pause: { await harness.pause() }))
    let radio = try OTATemporaryRadio(frequencyMHz: 909.5, bandwidthKHz: 500, spreadingFactor: 5, codingRate: 5, minutes: 120)
    try await workflow.run(container: package, radio: radio) { await progress.append($0) }
    #expect(await progress.messages.last?.contains("use ota speed 1 on the repeater") == true)
    #expect(await harness.calls.contains("local ota speed 0.5"))
    #expect(await harness.calls.contains("local normalradio"))
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
    let harness = OTAHarness(mid: "unused", mode: "speed success")
    let radio = try OTATemporaryRadio(frequencyMHz: 915, bandwidthKHz: 250, spreadingFactor: 5, codingRate: 5, minutes: 120)
    let workflow = LoRaOTAWorkflow(operations: .init(
      login: { try await harness.login() }, remote: { try await harness.remote($0) },
      local: { try await harness.local($0) }, startSource: { _ in try await harness.start() },
      stopSource: { await harness.stop() }, pause: { await harness.pause() }))
    let task = Task {
      do {
        try await workflow.run(container: container, radio: radio) { status in
          if status == "Checking repeater on temporary radio" {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
        Issue.record("Cancelled transfer unexpectedly succeeded")
      } catch { }
    }
    await task.value
    let calls = await harness.calls
    #expect(Array(calls.suffix(2)) == ["normalradio", "local normalradio"])
    #expect(calls.contains("stop"))
    #expect(calls.contains("ota speed 1"))
    #expect(calls.contains("local ota speed 0.5"))
    #expect(!calls.contains(where: { $0.hasPrefix("ota pull") }))
  }
}

private actor OTAProgressRecorder {
  var messages: [String] = []
  func append(_ message: String) { messages.append(message) }
}
