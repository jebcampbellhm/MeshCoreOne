import Foundation

/// Owns one Bluetooth catalog attachment, independently of remote OTA commands.
public actor MotaSourceSession {
  private let session: MeshCoreSession
  private let transport: any MotaTransport
  private let seeder: MotaSeeder
  private var worker: Task<Void, Never>?
  private var stopping = false
  public private(set) var failure: String?
  public private(set) var responsesSent = 0

  init(session: MeshCoreSession, transport: any MotaTransport, containers: [MotaContainer]) throws {
    self.session = session
    self.transport = transport
    self.seeder = try MotaSeeder(containers: containers)
  }

  func start() async throws {
    do {
      let requests = try await transport.openMotaChannel()
      guard !stopping else { throw CancellationError() }
      // Enumeration happens inside START. The worker must run first.
      worker = Task { [weak self] in
        do {
          for try await request in requests {
            try Task.checkCancellation()
            guard let self else { return }
            try await self.answer(request)
          }
          if !Task.isCancelled { await self?.failed("Bluetooth firmware channel closed") }
        } catch {
          if !Task.isCancelled { await self?.failed(error.localizedDescription) }
        }
      }
      let status = try await session.controlMotaSource(.status)
      guard status.channelReady, !status.anotherLinkActive, !status.attached else {
        throw MotaError.sourceBusy
      }
      let started = try await session.controlMotaSource(.start)
      guard !stopping, failure == nil, started.attached, started.offered == seeder.containers.count else {
        throw MotaError.invalidFrame
      }
    } catch {
      await stop()
      throw error
    }
  }

  private func answer(_ request: Data) async throws {
    guard !stopping else { throw CancellationError() }
    guard let response = seeder.response(to: request) else { throw MotaError.invalidFrame }
    try await transport.sendMotaResponse(response)
    responsesSent += 1
  }

  private func failed(_ message: String) async {
    failure = message
    await stop()
  }

  public func stop() async {
    guard !stopping else { return }
    stopping = true
    worker?.cancel()
    worker = nil
    // Unsubscribing also detaches the source in firmware. It works even if the
    // normal Companion command channel is wedged or a START reply was lost.
    await transport.closeMotaChannel()
    await session.releaseMotaSource(self)
  }
}
