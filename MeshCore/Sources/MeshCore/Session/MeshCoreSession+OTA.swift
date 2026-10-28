import Foundation

public extension MeshCoreSession {
  /// Non-mutating capability probe; does not subscribe, attach a source, or retune.
  func verifyMotaSupport() async throws {
    guard transport is any MotaTransport else { throw MotaError.unsupported }
    let status = try await controlMotaSource(.status)
    guard !status.attached, !status.anotherLinkActive else { throw MotaError.sourceBusy }
  }

  /// Starts serving a validated file. The returned session must be stopped when
  /// transfer ends. This does not change radio settings or initiate installation.
  func startMotaSource(container: MotaContainer) async throws -> MotaSourceSession {
    try await startMotaSource(containers: [container])
  }

  func startMotaSource(containers: [MotaContainer]) async throws -> MotaSourceSession {
    guard motaSource == nil else { throw MotaError.sourceBusy }
    guard let channel = transport as? any MotaTransport else { throw MotaError.unsupported }
    let source = try MotaSourceSession(session: self, transport: channel, containers: containers)
    motaSource = source
    do {
      try await source.start()
      return source
    } catch {
      if motaSource === source { motaSource = nil }
      throw error
    }
  }

  func stopMotaSource() async {
    let source = motaSource
    motaSource = nil
    await source?.stop()
  }

  /// Executes a permitted local command on the connected companion, not the repeater.
  func executeLocalOTAControl(_ command: String) async throws -> String {
    let frame = try await sendAndWaitWithError(
      CompanionOTAProtocol.localCommand(command),
      matching: { event -> Data? in
        if case let .otaControlReply(frame) = event { return frame }
        return nil
      },
      errorMatcher: Self.deviceErrorMatcher,
      timeout: 30
    )
    return try CompanionOTAProtocol.localReply(frame)
  }

  /// START requires an active request subscription and running seeder worker.
  func controlMotaSource(_ action: MotaSourceAction) async throws -> MotaSourceStatus {
    let frame = try await sendAndWaitWithError(
      CompanionOTAProtocol.sourceCommand(action),
      matching: { event -> Data? in
        if case let .otaControlReply(frame) = event { return frame }
        return nil
      },
      errorMatcher: Self.deviceErrorMatcher,
      timeout: 30
    )
    return try MotaSourceStatus(frame: frame, action: action)
  }
}

extension MeshCoreSession {
  func releaseMotaSource(_ source: MotaSourceSession) {
    if motaSource === source { motaSource = nil }
  }

  /// Called only while holding requestResponseSerializer, before sending.
  func prepareOTAReply(for command: UInt8?) {
    otaReplyCommand = command == 0x4A || command == 0x4B ? command : nil
    otaReplyBuffer.removeAll(keepingCapacity: true)
  }

  func consumeOTAReply(_ data: Data) async -> Bool {
    guard let command = otaReplyCommand, let first = data.first else { return false }
    // Push frames remain atomic and must continue through the ordinary parser.
    if first >= 0x80 { return false }
    if otaReplyBuffer.isEmpty, first != 0 { return false }
    otaReplyBuffer.append(data)
    if command == 0x4A, otaReplyBuffer.count >= 2,
       otaReplyBuffer.count < 2 + Int(otaReplyBuffer[1]) { return true }
    if command == 0x4A, otaReplyBuffer.count < 2 { return true }
    // Source replies fit in the minimum ATT payload (7 or 11 bytes).
    let frame = otaReplyBuffer
    otaReplyBuffer.removeAll(keepingCapacity: true)
    otaReplyCommand = nil
    await dispatcher.dispatch(.otaControlReply(frame))
    return true
  }
}
