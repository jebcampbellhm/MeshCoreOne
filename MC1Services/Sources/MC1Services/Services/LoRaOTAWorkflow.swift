import Foundation
import MeshCore

public struct OTATemporaryRadio: Sendable {
  public let command: String

  public init(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int,
              codingRate: Int, minutes: Int) throws {
    guard frequencyMHz.isFinite, (150...2500).contains(frequencyMHz),
          [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125, 250, 500].contains(bandwidthKHz),
          (5...12).contains(spreadingFactor), (5...8).contains(codingRate),
          (5...120).contains(minutes) else {
      throw LoRaOTAError.message("Enter valid radio settings and a window of 5–120 minutes.")
    }
    command = String(format: "tempradio %.3f,%.2f,%d,%d,%d", locale: Locale(identifier: "en_US_POSIX"),
                     frequencyMHz, bandwidthKHz, spreadingFactor, codingRate, minutes)
    self.minutes = minutes
  }

  public let minutes: Int
}

public enum LoRaOTAError: Error, LocalizedError, Sendable {
  case message(String)
  public var errorDescription: String? {
    switch self { case .message(let message): message }
  }
}

/// A single, foreground, direct-link transfer. Does not install or alter trust policy.
public struct LoRaOTAWorkflow: Sendable {
  public struct Operations: Sendable {
    public var prepare: @Sendable () async throws -> Void
    public var login: @Sendable () async throws -> Void
    public var remote: @Sendable (String) async throws -> String
    public var local: @Sendable (String) async throws -> String
    public var startSource: @Sendable (MotaContainer) async throws -> Void
    public var stopSource: @Sendable () async -> Void
    public var sourceFailure: @Sendable () async -> String?
    public var pause: @Sendable () async throws -> Void

    public init(prepare: @escaping @Sendable () async throws -> Void = {},
                login: @escaping @Sendable () async throws -> Void,
                remote: @escaping @Sendable (String) async throws -> String,
                local: @escaping @Sendable (String) async throws -> String,
                startSource: @escaping @Sendable (MotaContainer) async throws -> Void,
                stopSource: @escaping @Sendable () async -> Void,
                sourceFailure: @escaping @Sendable () async -> String? = { nil },
                pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) {
      self.prepare = prepare; self.login = login; self.remote = remote; self.local = local
      self.startSource = startSource; self.stopSource = stopSource
      self.sourceFailure = sourceFailure; self.pause = pause
    }
  }

  private let ops: Operations
  public init(operations: Operations, log: @escaping @Sendable (String) async -> Void = { _ in }) {
    ops = operations.logged(to: log)
  }

  @discardableResult
  public func run(container: MotaContainer, radio: OTATemporaryRadio,
                  speed: Double = 2,
                  clearExistingDownload: Bool = false,
                  progress: @escaping @Sendable (String) async -> Void) async throws -> String {
    try container.validateMeshTowerV2()
    let requestedSpeed = try OTASpeed.value(speed)
    let mid = container.manifestID.map { String(format: "%02X", $0) }.joined()
    var remoteChanged = false
    var localChanged = false
    var sourceStarted = false
    var restoreCache = false
    var restoreRemoteSpeed: String?
    var restoreLocalSpeed: String?
    var outcome: (any Error)?
    var deadline = ContinuousClock.now
    do {
      await progress("Checking companion")
      try await ops.prepare()
      await progress("Logging into repeater")
      try await loginWhenReady()
      let status = try await query("ota status")
      let hasExistingDownload = !status.contains("no download")
      guard !hasExistingDownload || clearExistingDownload else {
        throw LoRaOTAError.message("Repeater already has a download. Enable Clear existing download before transfer to discard it and start again.")
      }
      let identity = try await query("ota self")
      let storage = try await query("ota storage")
      try OTAPackageCompatibility.validate(container, status: status, identity: identity, storage: storage)
      if container.kind == .bootloader {
        try OTAPackageCompatibility.validateBootloader(container, reply: try await query("ota bootloader status"), ready: false)
      }
      let config = try await query("ota config")
      guard config.contains("autoinstall=off"), config.contains("autofetch=off") else {
        throw LoRaOTAError.message("Set ota config autoinstall off and ota config autofetch off before using this transfer-only screen.")
      }
      // Read both originals before changing either device. Track restoration
      // before each write because a timeout can hide a successful mutation.
      let remoteSpeed = try OTASpeed.savedValue(try await query("ota speed"))
      let localSpeed = try OTASpeed.savedValue(try await ops.local("ota speed"))
      await progress("Setting temporary OTA speed to \(speed)×")
      if Double(remoteSpeed) != speed {
        restoreRemoteSpeed = remoteSpeed
        try OTASpeed.confirm(try await ops.remote("ota speed \(requestedSpeed)"), expected: requestedSpeed)
      }
      if Double(localSpeed) != speed {
        restoreLocalSpeed = localSpeed
        try OTASpeed.confirm(try await ops.local("ota speed \(requestedSpeed)"), expected: requestedSpeed)
      }
      if OTAPackageCompatibility.fields(#"\bcache=(on|off)(?:/|\s|$)"#, in: config)?.first == "on" {
        await progress("Pausing automatic SD archive downloads")
        // Archive capture is independent of autofetch. Restore even after a lost
        // acknowledgement, which can mean this one-shot mutation took effect.
        restoreCache = true
        try Self.requireOK(try await ops.remote("ota cache off"))
        let paused = try await query("ota cache")
        guard paused.hasPrefix("SD OTA archive: capture=off") else {
          throw LoRaOTAError.message("Repeater did not confirm that automatic archive downloads are paused. \(paused)")
        }
      }
      if hasExistingDownload {
        try Task.checkCancellation()
        await progress("Clearing the repeater's existing download")
        // A lost reply cannot prove that the persistent receive slot was erased.
        // Never replay this mutation or start a new pull after an ambiguous result.
        do { try Self.requireOK(try await ops.remote("ota cancel")) }
        catch RemoteNodeError.timeout {
          throw LoRaOTAError.message("Download clear acknowledgement lost. Check the repeater before trying again; no new transfer was started.")
        }
        guard try await query("ota status").contains("no download") else {
          throw LoRaOTAError.message("Repeater did not confirm that its download was cleared. No new transfer was started.")
        }
      }
      try Task.checkCancellation()
      await progress("Moving repeater to temporary radio")
      deadline = ContinuousClock.now.advanced(by: .seconds(radio.minutes * 60 - 30))
      remoteChanged = true // Even a lost acknowledgement can mean the radio changed.
      do { try Self.requireOK(try await ops.remote(radio.command)) }
      catch RemoteNodeError.timeout {
        await progress("Radio acknowledgement lost; checking the repeater on the temporary channel")
      }
      try Task.checkCancellation()
      localChanged = true
      try Self.requireOK(try await ops.local(radio.command))
      // Firmware schedules retuning shortly after acknowledging the command.
      try await ops.pause()
      await progress("Starting Bluetooth seeder")
      try await ops.startSource(container)
      sourceStarted = true
      // Retuning does not invalidate the authenticated repeater session. Like
      // the Python runner, retain it and prove it with private read replies.
      // A redundant login can collide with the companion's pending RF slot.
      await progress("Waiting for temporary radio and seeder to settle")
      try await ops.pause()
      try Task.checkCancellation()
      await progress("Checking repeater on temporary radio")
      // Recheck the delta base and capabilities after the channel change, before
      // seeding can result in a pull. A reboot/other updater may have changed them.
      try OTAPackageCompatibility.validate(container, status: try await query("ota status"),
        identity: try await query("ota self"), storage: try await query("ota storage"))
      // Wait for advertisements; never guess the catalog's numeric index.
      var advertised = false
      for _ in 0..<12 {
        try Task.checkCancellation()
        for page in 1...16 {
          guard ContinuousClock.now < deadline else { throw LoRaOTAError.message("Temporary radio window ended during discovery.") }
          let catalog = try await query("ota ls \(page)")
          if catalog.uppercased().contains(mid) { advertised = true; break }
          if catalog.contains("out of range") || catalog.contains("No updates") { break }
        }
        if advertised { break }
        try await ops.pause()
      }
      guard advertised else { throw LoRaOTAError.message("Repeater has not advertised this file in its catalog. No pull was sent.") }
      // No automatic replacement of a download that appeared during discovery.
      guard try await query("ota status").contains("no download") else {
        throw LoRaOTAError.message("Another download appeared during preparation. No pull was sent.")
      }
      await progress("Requesting \(container.kind.rawValue.lowercased()) \(mid)")
      do { try Self.requireOK(try await ops.remote("ota pull \(mid) flash")) }
      catch RemoteNodeError.timeout {
        await progress("Pull acknowledgement lost; checking download status without resending")
      }
      while true {
        // Leave airtime for the actual transfer. Local Bluetooth service continues
        // answering requests during this quiet interval; reads can safely retry.
        for _ in 0..<6 { try await ops.pause() }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw LoRaOTAError.message("Transfer window ended before completion.") }
        if let failure = await ops.sourceFailure() { throw LoRaOTAError.message(failure) }
        // `ota status` truncates the download ID at 160 bytes on MeshTower.
        // The compact stats response puts it earlier; ignore the running firmware ID.
        let state = try await query("ota stats")
        await progress(state)
        let fetch = state.components(separatedBy: " | ").first { $0.hasPrefix("fetch ") } ?? ""
        guard fetch.uppercased().contains("ID=\(mid)") else {
          throw LoRaOTAError.message("Repeater did not confirm the selected download. \(state)")
        }
        if fetch.hasPrefix("fetch done ") { break }
        if fetch.hasPrefix("fetch failed") { throw LoRaOTAError.message(state) }
      }
      if container.kind == .bootloader {
        try OTAPackageCompatibility.validateBootloader(container, reply: try await query("ota bootloader status"), ready: true)
      }
    } catch { outcome = error }
    // Cleanup must still run when the screen's task was cancelled.
    let restoreRemote = remoteChanged
    let restoreLocal = localChanged
    let stop = sourceStarted
    let resumeCache = restoreCache
    let previousRemoteSpeed = restoreRemoteSpeed
    let previousLocalSpeed = restoreLocalSpeed
    let cleanup = await Task.detached { [ops] in
      if stop { await ops.stopSource() }
      var warnings: [String] = []
      if let previousRemoteSpeed {
        do { try OTASpeed.confirm(try await ops.remote("ota speed \(previousRemoteSpeed)"), expected: previousRemoteSpeed) }
        catch { warnings.append("Repeater speed restoration unconfirmed; use ota speed \(previousRemoteSpeed) on the repeater.") }
      }
      if let previousLocalSpeed {
        do { try OTASpeed.confirm(try await ops.local("ota speed \(previousLocalSpeed)"), expected: previousLocalSpeed) }
        catch { warnings.append("Companion speed restoration unconfirmed; use ota speed \(previousLocalSpeed) on the companion.") }
      }
      // Restore cache while the repeater is still on the same radio channel.
      if resumeCache {
        do { try Self.requireOK(try await ops.remote("ota cache on")) }
        catch { warnings.append("SD archive restoration unconfirmed; check ota cache and use ota cache on to restore it.") }
      }
      if restoreRemote {
        do { try Self.requireOK(try await ops.remote("normalradio")) }
        catch { warnings.append("Repeater radio restoration unconfirmed; its temporary window will expire.") }
      }
      if restoreLocal {
        do { try Self.requireOK(try await ops.local("normalradio")) }
        catch { warnings.append("Companion radio restoration unconfirmed; its temporary window will expire.") }
      }
      return warnings.joined(separator: " ")
    }.value
    if let outcome {
      throw LoRaOTAError.message("\(outcome.localizedDescription) \(cleanup)")
    }
    let instruction: String
    if container.kind == .bootloader {
      let hash = container.imageHash.prefix(8).map { String(format: "%02X", $0) }.joined()
      instruction = "Bootloader staged and exact ID/hash confirmed. After reviewing ota bootloader status, the separate install command is: ota bootloader install \(mid) \(hash)."
    } else {
      instruction = "\(container.kind.rawValue) ready on repeater SD card. Installation is separate."
    }
    await progress("\(instruction) \(cleanup)")
    if container.kind == .bootloader {
      let hash = container.imageHash.prefix(8).map { String(format: "%02X", $0) }.joined()
      return "ota bootloader install \(mid) \(hash)"
    }
    return "ota install"
  }

  /// Read the live receiver state without changing radios or issuing an install.
  public func readInstallCommand() async throws -> String {
    try await loginWhenReady()
    let status = try await query("ota status")
    let stats = try await query("ota stats")
    let bootloader = try await query("ota bootloader status")
    return try OTAInstallCommand.make(status: status, stats: stats, bootloaderStatus: bootloader)
  }

  /// Only read operations enter this retry path. Mutations always remain one-shot.
  private func query(_ command: String) async throws -> String {
    for attempt in 0..<3 {
      try Task.checkCancellation()
      do { return try await ops.remote(command) }
      catch {
        let timedOut: Bool
        if case RemoteNodeError.timeout = error { timedOut = true } else { timedOut = false }
        guard attempt < 2, timedOut || Self.isBusy(error) else { throw error }
        try await ops.pause()
      }
    }
    throw RemoteNodeError.timeout
  }

  private func loginWhenReady() async throws {
    for attempt in 0..<4 {
      try Task.checkCancellation()
      do { try await ops.login(); return }
      catch {
        // Code 0x04 rejects the login before transmission because the firmware
        // has an outstanding request. Do not retry passwords or other errors.
        guard attempt < 3, Self.isBusy(error) else { throw error }
        try await ops.pause()
      }
    }
  }

  private static func isBusy(_ error: any Error) -> Bool {
    if case MeshCoreError.deviceError(code: 0x04) = error { return true }
    if case RemoteNodeError.sessionError(.deviceError(code: 0x04)) = error { return true }
    return false
  }

  private static func requireOK(_ reply: String) throws {
    guard reply.hasPrefix("OK") else { throw LoRaOTAError.message(reply) }
  }
}

public extension LoRaOTAWorkflow {
  static func verifyCompanion(session: MeshCoreSession) async throws {
    guard try !OTADistribution.hasSavedJob() else {
      throw LoRaOTAError.message("Finish and restore the saved package distribution, then close that job before starting a single-file transfer.")
    }
    try await session.verifyMotaSupport()
    _ = try OTASpeed.savedValue(try await session.executeLocalOTAControl("ota speed"))
    let radio = try await session.executeLocalOTAControl("tempradio")
    guard radio.lowercased().hasPrefix("tempradio inactive") else {
      throw LoRaOTAError.message("Finish the companion's existing temporary radio session before starting this transfer.")
    }
  }

  static func connected(session: MeshCoreSession, remote: RemoteNodeService,
                        sessionID: UUID, password: String?,
                        log: @escaping @Sendable (String) async -> Void = { _ in }) -> LoRaOTAWorkflow {
    let source = OTASourceHolder()
    return LoRaOTAWorkflow(operations: Operations(
      prepare: {
        try await verifyCompanion(session: session)
        let time = try await session.getTime()
        guard abs(time.timeIntervalSinceNow) <= 600 else {
          throw LoRaOTAError.message("Companion clock differs from the phone by more than ten minutes. Synchronize it before OTA to avoid rejected admin packets.")
        }
      },
      login: {
        let result = try await remote.login(sessionID: sessionID, password: password)
        guard result.isAdmin else { throw LoRaOTAError.message("Repeater administrator login required.") }
      },
      remote: { try await remote.sendOTACommand(sessionID: sessionID, command: $0) },
      local: { try await session.executeLocalOTAControl($0) },
      startSource: { await source.set(try await session.startMotaSource(container: $0)) },
      stopSource: { await source.stop() },
      sourceFailure: { await source.failure() }
    ), log: log)
  }
}

private extension LoRaOTAWorkflow.Operations {
  func logged(to log: @escaping @Sendable (String) async -> Void) -> Self {
    let original = self
    return Self(
      prepare: { try await Self.record("Prepare companion", log: log, operation: original.prepare) },
      login: { try await Self.record("Repeater admin login (password omitted)", log: log, operation: original.login) },
      remote: { command in
        try await Self.record("Repeater: \(command)", log: log) { try await original.remote(command) }
      },
      local: { command in
        try await Self.record("Companion: \(command)", log: log) { try await original.local(command) }
      },
      startSource: { container in
        try await Self.record("Start Bluetooth seeder (\(container.kind.rawValue), \(container.bytes.count) bytes)", log: log) {
          try await original.startSource(container)
        }
      },
      stopSource: { await log("Stop Bluetooth seeder"); await original.stopSource(); await log("Seeder stopped") },
      sourceFailure: original.sourceFailure,
      pause: { try await Self.record("Wait for radio", log: log, operation: original.pause) }
    )
  }

  static func record<T: Sendable>(_ label: String, log: @Sendable (String) async -> Void,
                                operation: @Sendable () async throws -> T) async throws -> T {
    await log("BEGIN \(label)")
    do {
      let result = try await operation()
      await log("OK \(label): \(result)")
      return result
    } catch {
      await log("ERROR \(label): \(error.localizedDescription)")
      throw error
    }
  }
}

private actor OTASourceHolder {
  var source: MotaSourceSession?
  func set(_ value: MotaSourceSession) { source = value }
  func stop() async { await source?.stop(); source = nil }
  func failure() async -> String? { await source?.failure }
}
