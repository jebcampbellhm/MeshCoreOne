import Foundation

/// Resolves saved path hashes without silently choosing a colliding public key.
public enum OTADistributionRoute {
  public static func relayKeys(hops: [Data], knownKeys: [Data], destination: Data,
                               mirroredTrace: Bool = false) throws -> [Data] {
    var outbound = hops
    if mirroredTrace, !hops.isEmpty, !hops.count.isMultiple(of: 2) {
      let count = (hops.count + 1) / 2
      if Array(hops.dropFirst(count)) == Array(hops.prefix(count).reversed().dropFirst()) {
        outbound = Array(hops.prefix(count))
      }
    }
    let keys = Set(knownKeys + [destination])
    var resolved: [Data] = []
    for hash in outbound {
      guard [1, 2, 4].contains(hash.count) else { throw LoRaOTAError.message("Invalid saved hop hash") }
      let matches = keys.filter { $0.starts(with: hash) }
      guard matches.count == 1, let key = matches.first else {
        throw LoRaOTAError.message("Saved hop \(hash.map { String(format: "%02X", $0) }.joined()) is unknown or ambiguous. Choose that relay by its full public key.")
      }
      resolved.append(key)
    }
    if resolved.last == destination { resolved.removeLast() }
    guard resolved.count <= 2 else { throw LoRaOTAError.message("This path exceeds the two-relay limit; choose a shorter path.") }
    guard !resolved.contains(destination), Set(resolved).count == resolved.count else {
      throw LoRaOTAError.message("The path repeats a node or places the destination before the final hop.")
    }
    return resolved
  }
}
