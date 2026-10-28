import SwiftUI
import MC1Services
import MeshCore
import UniformTypeIdentifiers

struct OTADistributionView: View {
  let destination: RemoteNodeSessionDTO
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var sessions: [RemoteNodeSessionDTO] = []
  @State private var contacts: [ContactDTO] = []
  @State private var showSavedPaths = false
  @State private var relaySlot: Int?
  @State private var relaySearch = ""
  @State private var authContact: ContactDTO?
  @State private var relay1: UUID?
  @State private var relay2: UUID?
  @State private var packages: [MotaContainer] = []
  @State private var names: [String] = []
  @State private var importing = false
  @State private var frequency = "909.5"
  @State private var bandwidth = 500.0
  @State private var sf = 5
  @State private var minutes = 120
  @State private var speed = 2.0
  @State private var destinationUsesPrimary = false
  @State private var engine: OTADistribution?
  @State private var job: OTADistributionJob?
  @State private var busy = false
  @State private var seeding = false
  @State private var message = "Choose packages and up to two previously configured repeater sessions."
  @State private var work: Task<Void, Never>?
  @State private var oldIdleTimer = false

  var body: some View {
    NavigationStack {
      Form {
        if let job {
          Section("Distribution") {
            Text(job.message).textSelection(.enabled)
            if job.legacyDestinationID != nil { Text("Relays: tempradio2 · Destination: tempradio").font(.caption) }
            Text("Window ends \(job.expires.formatted(date: .omitted, time: .shortened))")
            ForEach(job.nodes) { node in
              VStack(alignment: .leading, spacing: 5) {
                Text(node.name).font(.headline)
                Text(node.key.prefix(6).map { String(format: "%02X", $0) }.joined()).font(.caption.monospaced())
                Text(node.detail).font(.caption).textSelection(.enabled)
                ForEach(job.packages) { package in
                  LabeledContent(package.name, value: !node.archive ? "Forward only" : node.offered.contains(package.id) ? "Cached · serving" : "Not yet confirmed")
                    .font(.caption)
                }
                if let date = node.checkedAt { Text("Checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption2) }
              }
            }
            Text("Cached does not mean ready to install. Use the single-file transfer screen to stage an exact compatible package for installation.")
              .font(.footnote)
          }
          Section("Controls") {
            if seeding {
              Button("Stop phone seeding") { perform { await engine?.stopSeeding(); seeding = false; restoreIdleTimer() } }
              Text(job.hasCompleteArchive ? "A selected SD node offers every package. It can serve while this phone is disconnected, until the radio window ends." : "Keep the phone seeding until an SD node offers every package. Stopping now can leave incomplete downloads.")
                .font(.footnote)
            } else if job.prepared && job.expires > Date() {
              Button("Start phone seeding") { perform {
                try await engine?.seed()
                oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
                seeding = true
              } }
            }
            Button("Refresh node status") { perform { try await engine?.refresh() } }
            Button("Finish and restore settings") { perform { await engine?.restore(); if seeding { restoreIdleTimer() }; seeding = false } }
            if job.changes.isEmpty {
              Button("Close completed distribution") { perform { try await engine?.dismissFinishedJob() } }
            }
          }.disabled(busy)
          if !job.changes.isEmpty {
            Section("Saved recovery commands") {
              ForEach(job.changes) { change in
                VStack(alignment: .leading) {
                  Text(change.node.flatMap { id in job.nodes.first { $0.id == id }?.name } ?? "Companion")
                  Text(change.restore).font(.caption.monospaced()).textSelection(.enabled)
                }
              }
              Text("This record survives app restarts. Use Finish and restore settings when done; speed/cache/hop settings do not expire with the radio window.")
                .font(.footnote)
            }
          }
        } else {
          Section("Package library") {
            Button("Choose .mota files (up to 8)") { importing = true }
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in Text(name) }
            Text("Signed firmware and bootloader packages for any target supported by the container format. Archive storage does not authorize installation.").font(.footnote)
          }
          Section("Route — nearest to farthest") {
            relayPicker("Relay 1", selection: $relay1, other: relay2, slot: 1)
            relayPicker("Relay 2", selection: $relay2, other: relay1, slot: 2)
            Button("Choose saved path") { showSavedPaths = true }
            if let contact = contacts.first(where: { $0.publicKey == destination.publicKey }), !contact.isFloodRouted {
              Button("Use destination’s current path (\(contact.pathHopCount) hops)") {
                importRoute(hops: contact.pathHops.map(\.data))
              }
            }
            Text("Destination: \(destination.name)")
            Text("Choose known repeaters or import a saved path in nearest-to-farthest order. Use Admin login for relays without saved credentials. This list manages participants; it does not change or pin the radio’s routing paths.").font(.footnote)
          }
          Section("Radio profiles") {
            Toggle("Older destination: use tempradio", isOn: $destinationUsesPrimary)
            Text(destinationUsesPrimary
              ? "Companion and relays use tempradio2. The destination temporarily leaves its normal channel using tempradio. Its contact routing is restored when finished."
              : "All participants use tempradio2, keeping their main channel available.").font(.footnote)
            Text("Companion and relays need secondary-profile support; existing secondary profiles and schedules must be off. All participants need compatible OTA firmware.").font(.footnote)
            TextField("Frequency MHz", text: $frequency).keyboardType(.decimalPad)
            Picker("Bandwidth", selection: $bandwidth) {
              ForEach([62.5, 125.0, 250.0, 500.0], id: \.self) { Text("\($0.formatted()) kHz").tag($0) }
            }
            Stepper("SF\(sf)", value: $sf, in: 5...12)
            Stepper("Window: \(minutes) minutes", value: $minutes, in: 5...120, step: 5)
            Picker("OTA speed", selection: $speed) {
              ForEach([0.5, 1.0, 2.0, 3.0], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
          }
          Section("Archive behavior") {
            Text("SD nodes capture and serve packages, including packages for other hardware. Internal/QSPI-only nodes forward. Archive capture may also collect other advertised packages during this window. Autofetch and autoinstall must already be off.")
              .font(.footnote)
            Button("Check route and prepare distribution") { prepare() }
              .disabled(packages.isEmpty || engine == nil)
          }
        }
        Section { Text(message).textSelection(.enabled); if busy { ProgressView() } }
      }
      .disabled(busy)
      .navigationTitle("Distribute OTA packages")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
      .interactiveDismissDisabled(busy)
      .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
        perform {
          let urls = try result.get()
          guard (1...8).contains(urls.count) else { throw LoRaOTAError.message("Choose 1–8 files") }
          let parsed = try await Task.detached {
            try urls.map { url in
              let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
              let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
              return try MotaContainer(archiveData: handle.read(upToCount: MotaContainer.maximumSize + 1) ?? Data())
            }
          }.value
          _ = try MotaSeeder(containers: parsed)
          packages = parsed; names = urls.map(\.lastPathComponent)
          message = "Packages verified. Ready to inspect the route."
        }
      }
      .task { await configure() }
      .task {
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(60)) } catch { break }
          if scenePhase == .active && !busy && job != nil {
            perform { try await engine?.refresh() }
          }
        }
      }
      .sheet(isPresented: $showSavedPaths) {
        SavedPathsSheet { path in
          showSavedPaths = false
          guard [1, 2, 4].contains(path.hashSize), path.pathBytes.count.isMultiple(of: path.hashSize) else {
            message = "Saved path has invalid hop data"; return
          }
          let bytes = Array(path.pathBytes)
          let hops = stride(from: 0, to: bytes.count, by: path.hashSize).map { Data(bytes[$0..<($0 + path.hashSize)]) }
          importRoute(hops: hops, mirroredTrace: true)
        }
      }
      .sheet(isPresented: Binding(get: { relaySlot != nil }, set: { if !$0 { relaySlot = nil } })) { knownRelayPicker }
      .sheet(item: $authContact) { contact in
        NodeAuthenticationSheet(contact: contact, role: .repeater) { _ in
          authContact = nil
          Task { await configure() }
        }
      }
      .onChange(of: relay1) { _, value in if value == nil { relay2 = nil } }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background { work?.cancel(); stopPhoneSource() }
      }
      .onDisappear { work?.cancel(); stopPhoneSource() }
    }
  }
  @ViewBuilder
  private func relayPicker(_ title: String, selection: Binding<UUID?>, other: UUID?, slot: Int) -> some View {
    Picker(title, selection: selection) {
      Text("None").tag(UUID?.none)
      ForEach(sessions.filter { $0.publicKey != destination.publicKey && $0.isRepeater && $0.id != other }) { node in
        Text("\(node.name) · \(node.publicKey.prefix(3).map { String(format: "%02X", $0) }.joined())").tag(Optional(node.id))
      }
    }
    Button("Choose \(title.lowercased()) from known repeaters") { relaySearch = ""; relaySlot = slot }
    if let selected = sessions.first(where: { $0.id == selection.wrappedValue }),
       let contact = contacts.first(where: { $0.publicKey == selected.publicKey }) {
      Button("Admin login: \(selected.name)") { authContact = contact }
    }
  }

  private func selectRelay(_ contact: ContactDTO, slot: Int) {
    relaySlot = nil
    perform {
      guard let services = appState.services else { return }
      let session = try await services.remoteNodeService.createSession(radioID: destination.radioID, contact: contact)
      await configure()
      if slot == 1 { relay1 = session.id } else { relay2 = session.id }
      message = "Selected \(session.name). Use Admin login if this relay has no saved credentials."
    }
  }

  private func importRoute(hops: [Data], mirroredTrace: Bool = false) {
    perform {
      guard let services = appState.services else { return }
      let keys = try OTADistributionRoute.relayKeys(hops: hops,
        knownKeys: contacts.filter { $0.type == .repeater }.map(\.publicKey) + sessions.filter(\.isRepeater).map(\.publicKey),
        destination: destination.publicKey, mirroredTrace: mirroredTrace)
      var selected: [UUID] = []
      for key in keys {
        if let existing = sessions.first(where: { $0.publicKey == key }) { selected.append(existing.id) }
        else if let contact = contacts.first(where: { $0.publicKey == key }) {
          selected.append(try await services.remoteNodeService.createSession(radioID: destination.radioID, contact: contact).id)
        }
      }
      await configure()
      relay1 = selected.first
      relay2 = selected.count > 1 ? selected[1] : nil
      message = "Loaded \(selected.count) relays in path order. Check Admin login for each relay before preparing."
    }
  }

  private var knownRelayPicker: some View {
    NavigationStack {
      List {
        let excluded = sessions.first { $0.id == (relaySlot == 1 ? relay2 : relay1) }?.publicKey
        let candidates = contacts.filter {
          $0.type == .repeater && $0.publicKey != destination.publicKey && $0.publicKey != excluded
            && HopNodeMatching.matches(.contact($0), query: relaySearch)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        ForEach(candidates) { contact in
          Button { selectRelay(contact, slot: relaySlot ?? 1) } label: {
            VStack(alignment: .leading) {
              Text(contact.displayName)
              Text(contact.publicKey.uppercaseHexString()).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
          }
        }
        if candidates.isEmpty { Text("No matching repeater contacts. Add the repeater to Contacts first.") }
      }
      .navigationTitle("Choose relay \(relaySlot ?? 1)")
      .searchable(text: $relaySearch, prompt: "Name or public key")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { relaySlot = nil } } }
    }
  }

  private func configure() async {
    guard let services = appState.services, appState.connectedDevice?.radioID == destination.radioID else {
      message = "Connect the companion used for this destination."; return
    }
    do {
      sessions = try await services.dataStore.fetchRemoteNodeSessions(radioID: destination.radioID)
      contacts = try await services.dataStore.fetchContacts(radioID: destination.radioID)
      let remote = services.remoteNodeService
      let local = services.session
      let expected = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.publicKey) })
      let store = services.dataStore
      let log = try LoRaOTASessionLog()
      let source = DistributionSource()
      let operations = OTADistribution.Operations(login: { id in
        guard let current = try await store.fetchRemoteNodeSession(id: id), current.publicKey == expected[id] else {
          throw LoRaOTAError.message("Node identity changed; refusing saved commands")
        }
        if current.isConnected && current.isAdmin { return }
        let login = try await remote.login(sessionID: id, pathLength: 2)
        guard login.isAdmin else { throw LoRaOTAError.message("Administrator login required") }
      }, command: { id, command in
        await log.append("\(id?.uuidString ?? "Companion"): \(command)")
        do {
          let reply: String
          if let id { reply = try await remote.sendSingleCLICommand(sessionID: id, command: command) }
          else if command.hasPrefix("ota ") { reply = try await local.executeLocalOTAControl(command) }
          else { reply = try await local.runCliCommand(command) }
          await log.append(reply)
          return reply
        } catch { await log.append("ERROR: \(error.localizedDescription)"); throw error }
      }, start: { containers in
        try await local.verifyMotaSupport()
        await source.set(try await local.startMotaSource(containers: containers))
      }, stop: { await local.stopMotaSource() }, failure: { await source.failure() })
      let candidate = try OTADistribution(operations: operations)
      let saved = await candidate.snapshot()
      if let saved {
        guard saved.radioID == destination.radioID,
              saved.nodes.allSatisfy({ expected[$0.id] == $0.key }) else {
          message = "Saved distribution belongs to another companion or changed node identity. Reconnect the original companion to recover it."; return
        }
      }
      engine = candidate; job = saved
    } catch { message = error.localizedDescription }
  }
  private func prepare() {
    perform {
      guard let services = appState.services else { throw LoRaOTAError.message("Connect the companion") }
      try await services.session.verifyMotaSupport()
      guard relay2 == nil || relay1 != nil else { throw LoRaOTAError.message("Choose Relay 1 before Relay 2") }
      let route = try [relay1, relay2].compactMap { $0 }.map { id -> OTADistributionNode in
        guard let session = sessions.first(where: { $0.id == id }) else { throw LoRaOTAError.message("Relay session unavailable") }
        return OTADistributionNode(session: session)
      } + [OTADistributionNode(session: destination)]
      try await engine?.prepare(radioID: destination.radioID, nodes: route, containers: packages, names: names,
        frequency: Double(frequency.replacingOccurrences(of: ",", with: ".")) ?? .nan,
        bandwidth: bandwidth, sf: sf, minutes: minutes, speed: speed, destinationUsesPrimary: destinationUsesPrimary)
      message = "Route prepared. Start phone seeding, then watch each node's catalog."
    }
  }
  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy, appState.connectedDevice?.radioID == destination.radioID else {
      message = "Reconnect the original companion before continuing."; return
    }
    busy = true
    work = Task {
      defer { busy = false; work = nil }
      do { try await action() } catch { message = error.localizedDescription }
      job = await engine?.snapshot()
      if seeding, await engine?.isSeeding() != true { restoreIdleTimer(); seeding = false }
    }
  }
  private func stopPhoneSource() {
    if seeding { restoreIdleTimer() }
    seeding = false
    let engine = engine
    Task { await engine?.stopSeeding() }
  }
  private func restoreIdleTimer() { UIApplication.shared.isIdleTimerDisabled = oldIdleTimer }
}

private actor DistributionSource {
  var source: MotaSourceSession?
  func set(_ value: MotaSourceSession) { source = value }
  func failure() async -> String? { await source?.failure }
}
