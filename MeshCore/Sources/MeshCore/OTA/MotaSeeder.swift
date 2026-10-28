import Foundation

/// Stateless, bounded request handler over one immutable verified image.
public struct MotaSeeder: Sendable {
  public let containers: [MotaContainer]
  public var container: MotaContainer { containers[0] }

  public init(container: MotaContainer) {
    self.containers = [container]
  }

  public init(containers: [MotaContainer]) throws {
    guard (1...8).contains(containers.count), Set(containers.map(\.manifestID)).count == containers.count else {
      throw MotaError.invalidContainer("Choose 1–8 packages with distinct manifest IDs")
    }
    self.containers = containers
  }

  /// Invalid envelopes are ignored. Valid requests with unsupported operations,
  /// malformed arguments, or out-of-range reads receive a protocol error.
  public func response(to request: Data) -> Data? {
    let frame = [UInt8](request)
    guard (4...11).contains(frame.count), frame[0] == 0x4D, frame[1] == 0x53,
          frame.dropFirst(2).dropLast().reduce(0, ^) == frame.last else { return nil }
    let operation = frame[2]
    let args = Array(frame.dropFirst(3).dropLast())
    var payload: Data?
    switch operation {
    case 1 where args.isEmpty:
      payload = Data([UInt8(containers.count)])
    case 2 where args.count == 1 && Int(args[0]) < containers.count:
      payload = containers[Int(args[0])].descriptor
    case 3 where args.count == 7 && Int(args[0]) < containers.count:
      let container = containers[Int(args[0])]
      let offset = Int(MotaWire.uint32(args, 1))
      let length = Int(args[5]) | Int(args[6]) << 8
      if length <= 192, offset <= container.bytes.count, length <= container.bytes.count - offset {
        payload = container.bytes.subdata(in: offset..<(offset + length))
      }
    default:
      break
    }
    var reply = Data([0x6D, 0x73, operation, payload == nil ? 1 : 0])
    reply.append(payload ?? Data())
    reply.append(reply.reduce(0, ^))
    return reply
  }
}
