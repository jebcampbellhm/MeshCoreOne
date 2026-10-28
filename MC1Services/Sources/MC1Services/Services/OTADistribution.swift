import Foundation
import MeshCore

public struct OTADistributionPackage: Codable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var target: String
}

public struct OTADistributionNode: Codable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var key: Data
  public var archive = false
  public var offered: [String] = []
  public var detail = "Not checked"
  public var checkedAt: Date?
  public init(session: RemoteNodeSessionDTO) {
    id = session.id; name = session.name; key = session.publicKey
  }
}

public struct OTADistributionChange: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var node: UUID? // nil is the paired companion
  public var read: String
  public var original: String
  public var applied: String
  public var restore: String
}

public struct OTADistributionJob: Codable, Sendable {
  public var radioID: UUID
  public var nodes: [OTADistributionNode] // near to far, destination last
  public var packages: [OTADistributionPackage]
  public var changes: [OTADistributionChange] = []
  public var expires: Date
  public var message = "Preparing"
  public var prepared = false
  public var legacyDestinationID: UUID?
  public var hasCompleteArchive: Bool {
    expires > Date() && nodes.contains { node in node.archive && node.checkedAt.map { Date().timeIntervalSince($0) < 120 } == true && packages.allSatisfy { node.offered.contains($0.id) } }
  }
}

public enum OTADistributionParsing {
  public static func scalar(_ reply: String) -> String {
    reply.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "> ", with: "")
  }
  public static func served(_ reply: String, packages: [OTADistributionPackage]) -> [String] {
    guard reply.hasPrefix("folder=off "), reply.contains("serving=") else { return [] }
    return packages.compactMap { package in
      // Own firmware (*) is not proof of a retained archive; require an exact
      // non-self catalog entry with both the requested MID and target.
      OTAPackageCompatibility.fields("(?:^| )(" + package.id + ")/" + package.target + "(?: |$)",
        in: reply.uppercased()) == nil ? nil : package.id
    }
  }
  public static func config(_ field: String, _ reply: String) throws -> String {
    guard let value = OTAPackageCompatibility.fields("\\b" + field + "=([^ /]+)", in: reply)?.first else {
      throw LoRaOTAError.message("Missing \(field) in reply: \(reply)")
    }
    return value
  }
  public static func contactRoute(_ reply: String) throws -> String {
    guard let mode = OTAPackageCompatibility.fields(#"key:[0-9A-Fa-f]{12} (auto|radio|radio2|both|off); active=[^\r\n]*$"#, in: reply)?.first else {
      throw LoRaOTAError.message("Companion did not report the destination contact's radio routing: \(reply)")
    }
    return mode
  }
  public static func primaryRadio(_ reply: String) throws -> String {
    let text = scalar(reply)
    if text == "off" || text.lowercased().hasPrefix("tempradio inactive") { return "off" }
    guard let parts = OTAPackageCompatibility.fields(#"^(\d+(?:\.\d+)?),(\d+(?:\.\d+)?),(\d+),(\d+)(?:,\d+)?$"#, in: text),
          let frequency = Double(parts[0]), let bandwidth = Double(parts[1]), let sf = Int(parts[2]), let cr = Int(parts[3]) else {
      throw LoRaOTAError.message("Destination did not report its temporary radio state: \(reply)")
    }
    return String(format: "%.3f,%.3f,%d,%d", locale: Locale(identifier: "en_US_POSIX"), frequency, bandwidth, sf, cr)
  }
  public static func radioTuple(_ reply: String) -> String {
    scalar(reply).components(separatedBy: ";")[0].components(separatedBy: " (auto)")[0]
  }
}

/// One durable, bounded distribution job. No passwords or private keys are saved.
/// The journal is written before every mutation, including mutations with lost ACKs.
public actor OTADistribution {
  public struct Operations: Sendable {
    public var login: @Sendable (UUID) async throws -> Void
    public var command: @Sendable (UUID?, String) async throws -> String
    public var start: @Sendable ([MotaContainer]) async throws -> Void
    public var stop: @Sendable () async -> Void
    public var failure: @Sendable () async -> String?
    public var pause: @Sendable () async throws -> Void
    public init(login: @escaping @Sendable (UUID) async throws -> Void,
                command: @escaping @Sendable (UUID?, String) async throws -> String,
                start: @escaping @Sendable ([MotaContainer]) async throws -> Void,
                stop: @escaping @Sendable () async -> Void,
                failure: @escaping @Sendable () async -> String? = { nil },
                pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) {
      self.login = login; self.command = command; self.start = start; self.stop = stop; self.failure = failure; self.pause = pause
    }
  }
  private let ops: Operations
  private let directory: URL
  private var job: OTADistributionJob?
  private var sourceActive = false
  public init(operations: Operations, directory: URL? = nil) throws {
    ops = operations
    self.directory = try directory ?? Self.storageDirectory()
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    let file = self.directory.appendingPathComponent("job.json")
    if FileManager.default.fileExists(atPath: file.path) {
      job = try JSONDecoder().decode(OTADistributionJob.self, from: Data(contentsOf: file))
    }
  }
  public nonisolated static func storageDirectory() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("MC1OTA-Distribution", isDirectory: true)
  }
  public nonisolated static func hasSavedJob() throws -> Bool {
    FileManager.default.fileExists(atPath: try storageDirectory().appendingPathComponent("job.json").path)
  }
  public func snapshot() -> OTADistributionJob? { job }
  public func isSeeding() -> Bool { sourceActive }
  private func save() throws {
    if let job { try JSONEncoder().encode(job).write(to: directory.appendingPathComponent("job.json"), options: .atomic) }
  }
  private func read(_ node: UUID?, _ command: String) async throws -> String {
    try Task.checkCancellation()
    return try await ops.command(node, command)
  }
  private func mutate(_ change: OTADistributionChange, command: String) async throws {
    job?.changes.append(change)
    try save()
    let reply = try await read(change.node, command)
    guard reply.hasPrefix("OK") else { throw LoRaOTAError.message("\(command): \(reply)") }
    try await ops.pause()
    let actual = try await normalizedRead(change)
    guard actual == change.applied || (change.read == "ota speed" && Double(actual) == Double(change.applied)) else {
      throw LoRaOTAError.message("Setting not confirmed: \(command). Read back: \(actual)")
    }
  }
  private func normalizedRead(_ change: OTADistributionChange) async throws -> String {
    let reply = try await ops.command(change.node, change.read)
    if change.read == "tempradio" { return try OTADistributionParsing.primaryRadio(reply) }
    if change.read.hasPrefix("get tx.user key:") { return try OTADistributionParsing.contactRoute(reply) }
    if change.read == "ota speed" { return try OTASpeed.savedValue(reply) }
    if change.read == "ota config" { return try OTADistributionParsing.config("hops", reply) }
    if change.read == "ota cache" {
      guard let value = OTAPackageCompatibility.fields(#"^SD OTA archive: capture=(on|off)\b"#, in: reply)?.first else {
        throw LoRaOTAError.message("Archive state unavailable: \(reply)")
      }
      return value
    }
    if change.read == "get tempradio2" { return OTADistributionParsing.radioTuple(reply) }
    return OTADistributionParsing.scalar(reply)
  }

  public func prepare(radioID: UUID, nodes: [OTADistributionNode], containers: [MotaContainer],
                      names: [String], frequency: Double, bandwidth: Double, sf: Int, minutes: Int, speed: Double,
                      destinationUsesPrimary: Bool = false) async throws {
    guard job == nil else { throw LoRaOTAError.message("Finish or recover the saved distribution first.") }
    guard (1...3).contains(nodes.count), Set(nodes.map(\.key)).count == nodes.count,
          nodes.allSatisfy({ $0.key.count == 32 }), names.count == containers.count else {
      throw LoRaOTAError.message("Choose a destination and at most two distinct relays.")
    }
    _ = try MotaSeeder(containers: containers)
    _ = try OTATemporaryRadio(frequencyMHz: frequency, bandwidthKHz: bandwidth, spreadingFactor: sf, codingRate: 5, minutes: minutes)
    let selectedSpeed = try OTASpeed.value(speed)
    guard containers.allSatisfy({ $0.blockSize <= 1024 && $0.blockCount <= 2048 }) else {
      throw LoRaOTAError.message("SD archive serving requires blocks no larger than 1024 bytes and at most 2048 blocks.")
    }
    let packages = zip(containers, names).map { package, name in
      OTADistributionPackage(id: package.manifestID.map { String(format: "%02X", $0) }.joined(),
        name: name, target: String(format: "%08X", package.targetID))
    }
    // Inspect all participants before writing any setting.
    let legacyID = destinationUsesPrimary ? nodes.last?.id : nil
    var legacyRoute: OTADistributionChange?
    if let destination = nodes.last, destinationUsesPrimary {
      let key = destination.key.map { String(format: "%02X", $0) }.joined()
      let query = "get tx.user key:\(key)"
      let original = try OTADistributionParsing.contactRoute(try await read(nil, query))
      guard ["auto", "radio", "both"].contains(original) else {
        throw LoRaOTAError.message("The older destination must initially be reachable over the normal radio profile.")
      }
      legacyRoute = .init(node: nil, read: query, original: original, applied: "both", restore: "set tx.user key:\(key) \(original)")
    }
    var checked = nodes
    var changes: [(OTADistributionChange, String)] = []
    let tuple = String(format: "%.3f,%.3f,%d,5,rxtx", locale: Locale(identifier: "en_US_POSIX"), frequency, bandwidth, sf)
    for participant in [Optional<UUID>.none] + nodes.map({ Optional($0.id) }) {
      if let participant { try await ops.login(participant) }
      var cross = "off"
      if let participant, participant == legacyID {
        guard try OTADistributionParsing.primaryRadio(try await read(participant, "tempradio")) == "off" else {
          throw LoRaOTAError.message("Finish the destination's existing temporary radio session first.")
        }
      } else {
        let temporary = try await read(participant, "get tempradio2")
        let savedRadio = try await read(participant, "get radio2")
        let liveRadio = try await read(participant, "get radio2.status")
        let schedule = try await read(participant, "get tempradioat2")
        let permanentSchedule = try await read(participant, "get radioat2")
        guard OTADistributionParsing.scalar(temporary) == "off", savedRadio.hasPrefix("> off"),
              liveRadio.hasPrefix("> off;"), !liveRadio.contains("pending"),
              OTADistributionParsing.scalar(schedule).trimmingCharacters(in: .whitespaces) == "slots:",
              OTADistributionParsing.scalar(permanentSchedule).trimmingCharacters(in: .whitespaces) == "slots:" else {
          throw LoRaOTAError.message("\(participant.flatMap { id in nodes.first { $0.id == id }?.name } ?? "Companion"): secondary radio must be off with no schedules before distribution.")
        }
        cross = OTADistributionParsing.scalar(try await read(participant, "get radio2.cross"))
        guard ["on", "off", "auto"].contains(cross) else { throw LoRaOTAError.message("Secondary-profile CLI unavailable; full firmware with local CLI support is required.") }
      }
      let oldSpeed = try OTASpeed.savedValue(try await read(participant, "ota speed"))
      let config = try await read(participant, "ota config")
      guard try OTADistributionParsing.config("autofetch", config) == "off",
            try OTADistributionParsing.config("autoinstall", config) == "off" else {
        throw LoRaOTAError.message("Set autofetch and autoinstall off on every participant before distribution; archive capture is managed separately.")
      }
      let oldHops = try OTADistributionParsing.config("hops", config)
      guard let hopCount = Int(oldHops), (0...8).contains(hopCount) else { throw LoRaOTAError.message("Invalid OTA hop limit") }
      let desiredHops = String(nodes.count - 1)
      if oldHops != desiredHops { changes.append((.init(node: participant, read: "ota config", original: oldHops, applied: desiredHops, restore: "ota config hops \(oldHops)"), "ota config hops \(desiredHops)")) }
      if Double(oldSpeed) != speed { changes.append((.init(node: participant, read: "ota speed", original: oldSpeed, applied: String(speed), restore: "ota speed \(oldSpeed)"), "ota speed \(selectedSpeed)")) }
      if cross != "off" { changes.append((.init(node: participant, read: "get radio2.cross", original: cross, applied: "off", restore: "set radio2.cross \(cross)"), "set radio2.cross off")) }
      if participant == nil, config.contains("cache=on/") {
        let cache = try await read(nil, "ota cache")
        guard cache.hasPrefix("SD OTA archive: capture=on") else { throw LoRaOTAError.message("Companion archive state could not be verified") }
        changes.append((.init(node: nil, read: "ota cache", original: "on", applied: "off", restore: "ota cache on"), "ota cache off"))
      }
      if let participant, let index = checked.firstIndex(where: { $0.id == participant }) {
        let cache = try await read(participant, "ota cache")
        let folder = try await read(participant, "ota folder")
        guard folder.hasPrefix("folder=off ") else { throw LoRaOTAError.message("Stop the other host source on \(checked[index].name) first.") }
        if let capture = OTAPackageCompatibility.fields(#"^SD OTA archive: capture=(on|off)\b"#, in: cache)?.first {
          checked[index].archive = true
          checked[index].offered = OTADistributionParsing.served(folder, packages: packages)
          checked[index].detail = cache
          if capture == "off" { changes.append((.init(node: participant, read: "ota cache", original: "off", applied: "on", restore: "ota cache off"), "ota cache on")) }
        } else if cache == "ERR this target has no SD-backed OTA archive" {
          checked[index].detail = "Forward only: no persistent SD archive"
        } else { throw LoRaOTAError.message("Archive capability could not be verified on \(checked[index].name): \(cache)") }
        let status = try await read(participant, "ota status")
        guard status.contains("no download") || cache.contains(", saving ") else {
          throw LoRaOTAError.message("\(checked[index].name) has an install download; finish it before distribution.")
        }
      }
    }
    guard checked.contains(where: \.archive) else { throw LoRaOTAError.message("At least one selected node needs a working SD archive. Internal/QSPI staging is not a multi-package archive.") }
    job = OTADistributionJob(radioID: radioID, nodes: checked, packages: packages, expires: Date().addingTimeInterval(Double(minutes * 60)))
    job?.legacyDestinationID = legacyID
    try save()
    do {
      for (package, meta) in zip(containers, packages) { try package.bytes.write(to: directory.appendingPathComponent(meta.id + ".mota"), options: .atomic) }
      for (change, command) in changes { try await mutate(change, command: command) }
      // Farthest first. Main-channel administration stays available throughout.
      for participant in nodes.reversed().filter({ $0.id != legacyID }).map({ Optional($0.id) }) + [nil] {
        let change = OTADistributionChange(node: participant, read: "get tempradio2", original: "off",
          applied: tuple, restore: "set tempradio2 off")
        job?.changes.append(change); try save()
        let reply = try await read(participant, "set tempradio2 \(tuple),\(minutes)")
        guard reply.hasPrefix("OK") else { throw LoRaOTAError.message(reply) }
        // Getters include the chosen preamble after the tuple. Store that exact
        // profile for ownership checks on recovery; never renew a lost lease.
        try await ops.pause()
        let actual = OTADistributionParsing.radioTuple(try await read(participant, "get tempradio2"))
        let live = try await read(participant, "get radio2.status")
        guard actual.hasPrefix(tuple + ","), live.hasPrefix("> rxtx;") else { throw LoRaOTAError.message("Temporary secondary radio not confirmed: \(actual)") }
        let lastChange = (job?.changes.count ?? 1) - 1
        job?.changes[lastChange].applied = actual; try save()
      }
      if let legacyID, let legacyRoute {
        // The normal channel still reaches the destination while relays now
        // listen on both profiles. Journal routing BEFORE moving the target.
        job?.changes.append(legacyRoute)
        let primary = String(format: "%.3f,%.3f,%d,5", locale: Locale(identifier: "en_US_POSIX"), frequency, bandwidth, sf)
        job?.changes.append(.init(node: legacyID, read: "tempradio", original: "off", applied: primary, restore: "normalradio"))
        try save()
        do {
          let reply = try await read(legacyID, "tempradio \(primary),\(minutes)")
          guard reply.hasPrefix("OK") else { throw LoRaOTAError.message(reply) }
        } catch RemoteNodeError.timeout {
          // It may already have switched. Prove the state on the prepared path;
          // never extend a temporary lease by replaying the command.
        }
        try await ensureLegacyRouting(legacyRoute)
        try await ops.pause()
        guard try OTADistributionParsing.primaryRadio(try await read(legacyID, "tempradio")) == primary else {
          throw LoRaOTAError.message("Older destination's temporary radio was not confirmed")
        }
      }
      job?.prepared = true; job?.message = "Prepared; start phone seeding or refresh existing archives"; try save()
    } catch {
      let failure = error.localizedDescription
      await Task.detached { await self.restore() }.value
      job?.message = failure + " Check recovery commands below."; try? save()
      throw LoRaOTAError.message(failure)
    }
  }

  public func seed() async throws {
    guard let job, job.prepared, job.expires > Date(), !sourceActive else { throw LoRaOTAError.message("No active prepared distribution window") }
    let containers = try job.packages.map { try MotaContainer(archiveData: Data(contentsOf: directory.appendingPathComponent($0.id + ".mota"))) }
    do {
      try await ops.start(containers); sourceActive = true
      self.job?.message = "Phone seeding; keep this screen open until an archive offers every package"; try save()
    } catch {
      await ops.stop(); sourceActive = false
      throw error
    }
  }
  public func stopSeeding() async {
    await ops.stop(); sourceActive = false
    job?.message = "Phone source stopped. Only verified node archives can continue serving; refresh to check progress."
    try? save()
  }
  public func refresh() async throws {
    guard let current = job else { return }
    let sourceError = sourceActive ? await ops.failure() : nil
    if sourceError != nil { await ops.stop(); sourceActive = false }
    for index in current.nodes.indices {
      let node = current.nodes[index]
      do {
        try Task.checkCancellation()
        try await ops.login(node.id)
        let cache = try await read(node.id, "ota cache")
        let folder = try await read(node.id, "ota folder")
        job?.nodes[index].offered = node.archive ? OTADistributionParsing.served(folder, packages: current.packages) : []
        job?.nodes[index].detail = node.archive ? cache : "Forward only"
        job?.nodes[index].checkedAt = Date()
      } catch {
        job?.nodes[index].offered = []
        job?.nodes[index].detail = "Unconfirmed: \(error.localizedDescription)"
        job?.nodes[index].checkedAt = nil
      }
    }
    job?.message = current.expires <= Date() ? "Radio window expired. Finish and restore settings before starting another window." : "Status refreshed; catalog replies may be truncated, so absent IDs remain unconfirmed."
    if let sourceError { job?.message = "Phone source failed: \(sourceError). Node archives may continue; refresh or restart seeding." }
    try save()
  }
  private func ensureLegacyRouting(_ route: OTADistributionChange) async throws {
    let current = try await normalizedRead(route)
    guard current == route.original || current == "both" else {
      throw LoRaOTAError.message("Destination contact routing changed externally; restore it manually before recovering this route.")
    }
    if current != "both" {
      let command = route.read.replacingOccurrences(of: "get tx.user ", with: "set tx.user ") + " both"
      let reply = try await ops.command(nil, command)
      guard reply.hasPrefix("OK") else { throw LoRaOTAError.message(reply) }
      try await ops.pause()
      guard try await normalizedRead(route) == "both" else { throw LoRaOTAError.message("Destination routing not confirmed") }
    }
  }

  public func restore() async {
    await ops.stop(); sourceActive = false
    guard let current = job else { return }
    job?.prepared = false
    // Settings before leases; distant nodes before the companion. Primary
    // management stays on the primary channel except for the legacy destination.
    if current.changes.contains(where: { $0.read == "tempradio" }),
       let route = current.changes.first(where: { $0.read.hasPrefix("get tx.user key:") }) {
      do { try await ensureLegacyRouting(route) }
      catch {
        job?.message = "Mixed-radio recovery needs the destination route: \(error.localizedDescription). Relay windows remain available until expiry."
        try? save(); return
      }
    }
    let order = current.nodes.reversed().map({ Optional($0.id) }) + [nil]
    var warnings: [String] = []
    for node in order {
      if let node {
        do { try await ops.login(node) }
        catch {
          warnings.append("Login failed for \(node)")
          if node == current.legacyDestinationID { warnings.append("Relay path retained until lease expiry"); break }
          continue
        }
      }
      let owned = current.changes.filter { $0.node == node }.sorted {
        func rank(_ read: String) -> Int { read == "get radio2.cross" ? 2 : (read == "get tempradio2" || read == "tempradio") ? 1 : 0 }
        return rank($0.read) < rank($1.read)
      }
      for change in owned {
        do {
          let actual = try await normalizedRead(change)
          if actual != change.original {
            // Do not overwrite a setting another operator changed.
            let same = actual == change.applied || (change.read == "ota speed" && Double(actual) == Double(change.applied))
              || (change.read == "get tempradio2" && actual.hasPrefix(change.applied + ","))
            guard same else { throw LoRaOTAError.message("Setting changed externally: \(change.read)") }
            let reply = try await ops.command(node, change.restore)
            guard reply.hasPrefix("OK") else { throw LoRaOTAError.message(reply) }
            try await ops.pause()
            guard try await normalizedRead(change) == change.original else { throw LoRaOTAError.message("Restore not confirmed") }
          }
          job?.changes.removeAll { $0.id == change.id }; try save()
        } catch { warnings.append("\(change.restore): \(error.localizedDescription)") }
      }
      if node == current.legacyDestinationID, node != nil,
         job?.changes.contains(where: { $0.node == node }) == true {
        warnings.append("Destination recovery is incomplete; relay and companion profiles are retained until their leases expire. Retry recovery before expiry if possible.")
        break
      }
    }
    job?.prepared = false
    job?.message = warnings.isEmpty ? "Settings restored; cached packages remain on the nodes" : warnings.joined(separator: "\n")
    try? save()
  }
  public func dismissFinishedJob() throws {
    guard let job, job.changes.isEmpty else { throw LoRaOTAError.message("Restore all pending settings before clearing this job") }
    for package in job.packages { try? FileManager.default.removeItem(at: directory.appendingPathComponent(package.id + ".mota")) }
    try FileManager.default.removeItem(at: directory.appendingPathComponent("job.json")); self.job = nil
  }
}
