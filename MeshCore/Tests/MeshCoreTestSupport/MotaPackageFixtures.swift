import Foundation

/// Synthetic, independently signed packages using the PUBLIC test key 00..1f.
/// These are parser/protocol fixtures, never flashable firmware releases.
public enum MotaPackageFixtures {
  public static func data(_ name: String, extension ext: String = "mota") throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
  }
}
