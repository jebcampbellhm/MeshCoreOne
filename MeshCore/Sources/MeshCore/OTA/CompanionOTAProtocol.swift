import Foundation

public enum MotaSourceAction: UInt8, Sendable {
  case status = 0
  case start = 1
  case stop = 2
}

public struct MotaSourceStatus: Sendable, Equatable {
  public let channelReady: Bool
  public let attached: Bool
  public let anotherLinkActive: Bool
  public let offered: UInt16
  public let advertised: UInt16
  public let packetsSent: UInt32?

  public init(frame: Data, action: MotaSourceAction) throws {
    let bytes = [UInt8](frame)
    guard [7, 11].contains(bytes.count), bytes[0] == 0, bytes[1] == action.rawValue else {
      throw MotaError.invalidFrame
    }
    channelReady = bytes[2] & 1 != 0
    attached = bytes[2] & 2 != 0
    anotherLinkActive = bytes[2] & 4 != 0
    offered = UInt16(bytes[3]) | UInt16(bytes[4]) << 8
    advertised = UInt16(bytes[5]) | UInt16(bytes[6]) << 8
    packetsSent = bytes.count == 11 ? MotaWire.uint32(bytes, 7) : nil
  }
}

public enum CompanionOTAProtocol {
  public static let serviceUUID = "14518fc2-7e7a-4d84-8cae-6664b0234cf2"
  public static let requestUUID = "2bfaa1ee-7030-459a-b65a-e7cfd5b09735"
  public static let responseUUID = "acf38a51-dd58-4dce-917f-0b1135e41b1a"

  public static func sourceCommand(_ action: MotaSourceAction) -> Data {
    Data([0x4B, action.rawValue])
  }

  public static func localCommand(_ command: String) throws -> Data {
    let bytes = Array(command.utf8)
    let prohibited = Set(";&|`$\\'\"".utf8)
    let tokens = command.split(separator: " ")
    guard (1...174).contains(bytes.count),
          bytes.allSatisfy({ (0x20...0x7E).contains($0) && !prohibited.contains($0) }),
          command == "normalradio" || command == "tempradio" || command.hasPrefix("tempradio ")
            || (tokens.first == "ota" && tokens.dropFirst().first != "folder"
              && tokens.dropFirst().first != "fold") else {
      throw MeshCoreError.invalidInput("Unsupported local OTA control command")
    }
    return Data([0x4A] + bytes)
  }

  public static func localReply(_ frame: Data) throws -> String {
    let bytes = [UInt8](frame)
    guard bytes.count >= 2, bytes[0] == 0, Int(bytes[1]) + 2 == bytes.count,
          let result = String(bytes: bytes.dropFirst(2), encoding: .ascii) else {
      throw MotaError.invalidFrame
    }
    return result
  }
}
