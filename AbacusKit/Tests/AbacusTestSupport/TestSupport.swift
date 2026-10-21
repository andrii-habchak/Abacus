import Foundation
import Testing

extension Tag {
  /// Tests that read the owner's real exports. They skip when the files are missing (CI, fresh
  /// worktrees). Never copy real data into fixtures (R-NF-6).
  @Tag public static var realData: Self
}

public enum RealSamples {
  /// `$ABACUS_SAMPLES`, else `<repo>/samples/private/`.
  public static var directory: URL {
    if let path = ProcessInfo.processInfo.environment["ABACUS_SAMPLES"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    // <repo>/AbacusKit/Tests/AbacusTestSupport/TestSupport.swift → <repo>
    return URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "samples/private", directoryHint: .isDirectory)
  }

  /// Use as `.enabled(if: RealSamples.has(prefix: "saldo"))` so tests skip without the files.
  public static func has(prefix: String) -> Bool { file(prefix: prefix) != nil }

  /// The first file in the samples folder whose name starts with `prefix`, if any.
  public static func file(prefix: String) -> URL? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.sorted().first { $0.hasPrefix(prefix) }.map { directory.appending(path: $0) }
  }
}
