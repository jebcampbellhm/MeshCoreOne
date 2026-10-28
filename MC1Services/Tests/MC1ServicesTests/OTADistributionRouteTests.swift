import Foundation
import Testing
@testable import MC1Services

struct OTADistributionRouteTests {
  let a = Data(repeating: 1, count: 32)
  let b = Data(repeating: 2, count: 32)
  let destination = Data(repeating: 3, count: 32)

  @Test(arguments: [1, 2, 4])
  func importsOutboundAndMirroredTrace(width: Int) throws {
    let outbound = [a, b].map { Data($0.prefix(width)) }
    let end = Data(destination.prefix(width))
    #expect(try OTADistributionRoute.relayKeys(hops: outbound, knownKeys: [a, b], destination: destination) == [a, b])
    #expect(try OTADistributionRoute.relayKeys(hops: outbound + [end], knownKeys: [a, b], destination: destination) == [a, b])
    #expect(try OTADistributionRoute.relayKeys(hops: outbound + [end] + outbound.reversed(), knownKeys: [a, b], destination: destination, mirroredTrace: true) == [a, b])
  }

  @Test func rejectsAmbiguousUnknownRepeatedAndOverlongPaths() {
    let collision = Data([1] + Array(repeating: 9, count: 31))
    #expect(throws: (any Error).self) {
      try OTADistributionRoute.relayKeys(hops: [Data([1])], knownKeys: [a, collision], destination: destination)
    }
    for hops in [[Data([9])], [Data([1]), Data([1])], [Data([3]), Data([1])], [Data([1]), Data([2]), Data([4])]] {
      #expect(throws: (any Error).self) {
        try OTADistributionRoute.relayKeys(hops: hops, knownKeys: [a, b, Data(repeating: 4, count: 32)], destination: destination)
      }
    }
  }

  @Test func directPathAndDuplicateSources() throws {
    #expect(try OTADistributionRoute.relayKeys(hops: [], knownKeys: [], destination: destination).isEmpty)
    #expect(try OTADistributionRoute.relayKeys(hops: [Data([1])], knownKeys: [a, a], destination: destination) == [a])
  }
}
