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
    public var login: @Sendable () async throws -> Void
    public var remote: @Sendable (String) async throws -> String
    public var local: @Sendable (String) async throws -> String
    public var startSource: @Sendable (MotaContainer) async throws -> Void
    public var stopSource: @Sendable () async -> Void
    public var sourceFailure: @Sendable () async -> String?
    public var pause: @Sendable () async throws -> Void

    public init(login: @escaping @Sendable () async throws -> Void,
                remote: @escaping @Sendable (String) async throws -> String,
                local: @escaping @Sendable (String) async throws -> String,
                startSource: @escaping @Sendable (MotaContainer) async throws -> Void,
                stopSource: @escaping @Sendable () async -> Void,
                sourceFailure: @escaping @Sendable () async -> String? = { nil },
                pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) {
      self.login = login; self.remote = remote; self.local = local
      self.startSource = startSource; self.stopSource = stopSource
      self.sourceFailure = sourceFailure; self.pause = pause
    }
  }

  private let ops: Operations
  public init(operations: Operations) { ops = operations }

  public func run(container: MotaContainer, radio: OTATemporaryRadio,
                  progress: @escaping @Sendable (String) async -> Void) async throws {
    try container.validateMeshTowerV2()
    let mid = container.manifestID.map { String(format: "%02X", $0) }.joined()
    var remoteChanged = false
    var localChanged = false
    var sourceStarted = false
    var outcome: (any Error)?
    var deadline = ContinuousClock.now
    do {
      await progress("Logging into repeater")
      try await ops.login()
      let status = try await ops.remote("ota status")
      guard status.contains("hw=Heltec_tower_v2"), status.uppercased().contains("TARGET:0A9DBBF0") else {
        throw LoRaOTAError.message("Repeater does not report the required MeshTower V2 OTA target.")
      }
      guard status.contains("no download") else {
        throw LoRaOTAError.message("Repeater already has a download. Resolve it in the terminal before starting another.")
      }
      let maxBlock = status.components(separatedBy: "maxblk:").dropFirst().first?
        .prefix(while: { $0.isNumber })
      guard let maxBlock, let capacity = Int(maxBlock), container.blockSize <= capacity else {
        throw LoRaOTAError.message("Repeater does not support this firmware package's block size.")
      }
      let storage = try await ops.remote("ota storage")
      guard storage.contains("SD staging;") else {
        throw LoRaOTAError.message("Full updates require mounted SD staging and a compatible OTAFIX bootloader. \(storage)")
      }
      let config = try await ops.remote("ota config")
      guard config.contains("autoinstall=off") else {
        throw LoRaOTAError.message("Set ota config autoinstall off before using this transfer-only screen.")
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
      await progress("Logging into repeater on temporary radio")
      try await ops.login()
      // Wait for advertisements; never guess the catalog's numeric index.
      var advertised = false
      for _ in 0..<12 {
        try Task.checkCancellation()
        for page in 1...16 {
          guard ContinuousClock.now < deadline else { throw LoRaOTAError.message("Temporary radio window ended during discovery.") }
          let catalog = try await ops.remote("ota ls \(page)")
          if catalog.uppercased().contains(mid) { advertised = true; break }
          if catalog.contains("out of range") || catalog.contains("No updates") { break }
        }
        if advertised { break }
        try await ops.pause()
      }
      guard advertised else { throw LoRaOTAError.message("Repeater has not advertised this file in its catalog. No pull was sent.") }
      await progress("Requesting full update \(mid)")
      do { try Self.requireOK(try await ops.remote("ota pull \(mid) flash")) }
      catch RemoteNodeError.timeout {
        await progress("Pull acknowledgement lost; checking download status without resending")
      }
      while true {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw LoRaOTAError.message("Transfer window ended before completion.") }
        if let failure = await ops.sourceFailure() { throw LoRaOTAError.message(failure) }
        // `ota status` truncates the download ID at 160 bytes on MeshTower.
        // The compact stats response puts it earlier; ignore the running firmware ID.
        let state = try await ops.remote("ota stats")
        await progress(state)
        let fetch = state.components(separatedBy: " | ").first { $0.hasPrefix("fetch ") } ?? ""
        guard fetch.uppercased().contains("ID=\(mid)") else {
          throw LoRaOTAError.message("Repeater did not confirm the selected download. \(state)")
        }
        if fetch.hasPrefix("fetch done ") { break }
        if fetch.hasPrefix("fetch failed") { throw LoRaOTAError.message(state) }
        try await ops.pause()
      }
    } catch { outcome = error }
    // Cleanup must still run when the screen's task was cancelled.
    let restoreRemote = remoteChanged
    let restoreLocal = localChanged
    let stop = sourceStarted
    let cleanup = await Task.detached { [ops] in
      if stop { await ops.stopSource() }
      var warnings: [String] = []
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
    await progress("File ready on repeater SD card. \(cleanup)")
  }

  private static func requireOK(_ reply: String) throws {
    guard reply.hasPrefix("OK") else { throw LoRaOTAError.message(reply) }
  }
}

public extension LoRaOTAWorkflow {
  static func connected(session: MeshCoreSession, remote: RemoteNodeService,
                        sessionID: UUID, password: String?) -> LoRaOTAWorkflow {
    let source = OTASourceHolder()
    return LoRaOTAWorkflow(operations: Operations(
      login: {
        let result = try await remote.login(sessionID: sessionID, password: password)
        guard result.isAdmin else { throw LoRaOTAError.message("Repeater administrator login required.") }
      },
      remote: { try await remote.sendOTACommand(sessionID: sessionID, command: $0) },
      local: { try await session.executeLocalOTAControl($0) },
      startSource: { await source.set(try await session.startMotaSource(container: $0)) },
      stopSource: { await source.stop() },
      sourceFailure: { await source.failure() }
    ))
  }
}

private actor OTASourceHolder {
  var source: MotaSourceSession?
  func set(_ value: MotaSourceSession) { source = value }
  func stop() async { await source?.stop(); source = nil }
  func failure() async -> String? { await source?.failure }
}
