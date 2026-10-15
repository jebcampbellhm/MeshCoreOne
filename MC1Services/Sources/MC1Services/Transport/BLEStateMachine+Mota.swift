@preconcurrency import CoreBluetooth
import Foundation
import MeshCore

extension BLEStateMachine {
  /// Discover on demand after the normal Companion connection is established.
  /// An unsupported service never changes ordinary connection readiness.
  func openMotaChannel() async throws -> AsyncThrowingStream<Data, Error> {
    guard case let .connected(peripheral, _, _, _) = phase else { throw BLEError.notConnected }
    guard motaSetup == nil, motaRequest == nil else { throw MotaError.sourceBusy }
    let generation = motaGeneration
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        motaSetup = continuation
        motaSetupTimeout = Task {
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          closeMotaChannel(ifGeneration: generation, error: BLEError.operationTimeout)
        }
        peripheral.discoverServices([CBUUID(string: CompanionOTAProtocol.serviceUUID)])
      }
    } onCancel: {
      Task { await self.closeMotaChannel(ifGeneration: generation, error: CancellationError()) }
    }
  }

  private func closeMotaChannel(ifGeneration generation: UInt64, error: Error) {
    guard generation == motaGeneration else { return }
    closeMotaChannel(error: error)
  }

  func closeMotaChannel(error: Error = BLEError.notConnected) {
    motaGeneration &+= 1
    motaSetupTimeout?.cancel()
    motaSetupTimeout = nil
    let setup = motaSetup
    motaSetup = nil
    setup?.resume(throwing: error)
    delegateHandler.setMotaContinuation(nil)
    if case let .connected(peripheral, _, _, _) = phase, let request = motaRequest {
      peripheral.setNotifyValue(false, for: request)
    }
    motaRequest = nil
    motaResponse = nil
  }

  func handleMotaServices(_ peripheral: CBPeripheral, error: Error?) -> Bool {
    guard case let .connected(expected, _, _, _) = phase,
          peripheral === expected, motaSetup != nil else { return false }
    guard error == nil,
          let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: CompanionOTAProtocol.serviceUUID)
          }) else {
      closeMotaChannel(error: error ?? MotaError.unsupported)
      return true
    }
    peripheral.discoverCharacteristics([
      CBUUID(string: CompanionOTAProtocol.requestUUID),
      CBUUID(string: CompanionOTAProtocol.responseUUID)
    ], for: service)
    return true
  }

  func handleMotaCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) -> Bool {
    guard service.uuid == CBUUID(string: CompanionOTAProtocol.serviceUUID) else { return false }
    guard case let .connected(expected, _, _, _) = phase,
          peripheral === expected, motaSetup != nil else { return true }
    guard error == nil,
          let request = service.characteristics?.first(where: {
            $0.uuid == CBUUID(string: CompanionOTAProtocol.requestUUID) && $0.properties.contains(.notify)
          }),
          let response = service.characteristics?.first(where: {
            $0.uuid == CBUUID(string: CompanionOTAProtocol.responseUUID) && $0.properties.contains(.write)
          }) else {
      closeMotaChannel(error: error ?? MotaError.unsupported)
      return true
    }
    motaRequest = request
    motaResponse = response
    peripheral.setNotifyValue(true, for: request)
    return true
  }

  func handleMotaSubscription(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) -> Bool {
    guard characteristic.uuid == CBUUID(string: CompanionOTAProtocol.requestUUID) else { return false }
    guard case let .connected(expected, _, _, _) = phase,
          peripheral === expected, characteristic === motaRequest else { return true }
    guard error == nil, characteristic.isNotifying else {
      closeMotaChannel(error: error ?? MotaError.unsupported)
      return true
    }
    guard let setup = motaSetup else { return true }
    let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
    delegateHandler.setMotaContinuation((peripheral.identifier, continuation))
    motaSetup = nil
    motaSetupTimeout?.cancel()
    motaSetupTimeout = nil
    setup.resume(returning: stream)
    return true
  }

  func sendMotaResponse(_ frame: Data) async throws {
    guard (5...197).contains(frame.count) else { throw MotaError.invalidFrame }
    let generation = motaGeneration
    try await motaWriteSerializer.withSerialization { [self] in
      try await writeMotaResponse(frame, generation: generation)
    }
  }

  private func writeMotaResponse(_ frame: Data, generation: UInt64) async throws {
    guard case let .connected(peripheral, _, _, _) = phase,
          let response = motaResponse, motaRequest?.isNotifying == true else { throw BLEError.notConnected }
    let chunkSize = min(197, peripheral.maximumWriteValueLength(for: .withResponse))
    guard chunkSize > 0 else { throw MotaError.unsupported }
    for offset in stride(from: 0, to: frame.count, by: chunkSize) {
      try Task.checkCancellation()
      guard generation == motaGeneration else { throw BLEError.notConnected }
      try await claimWriteSlot(
        data: frame.subdata(in: offset..<min(offset + chunkSize, frame.count)),
        characteristic: response
      )
    }
  }
}
