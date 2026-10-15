import Foundation

/// Optional second channel on the companion's existing connection.
public protocol MotaTransport: MeshTransport {
  func openMotaChannel() async throws -> AsyncThrowingStream<Data, Error>
  func sendMotaResponse(_ frame: Data) async throws
  func closeMotaChannel() async
}
