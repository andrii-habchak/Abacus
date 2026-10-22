import AbacusFeatures
import Foundation
import Testing

@Suite("Launch database selection (C2)")
struct LaunchDatabaseTests {
  static let defaultFile = URL(filePath: "/Users/someone/Library/Application Support/Abacus/abacus.sqlite")
  static let remembered = URL(filePath: "/Volumes/Finance/abacus.sqlite")

  /// Fails the test if the default location is asked for when it must not be.
  struct UnexpectedDefault: Error {}

  func choose(
    path: String? = nil, preview: Bool = false, remembered: URL? = nil, existing: Set<URL> = [],
    defaultAllowed: Bool = true
  ) throws -> AppBootstrap.LaunchDatabase {
    try AppBootstrap.launchDatabase(
      databasePath: path, previewData: preview, remembered: remembered, fileExists: { existing.contains($0) },
      defaultURL: {
        guard defaultAllowed else { throw UnexpectedDefault() }
        return Self.defaultFile
      })
  }

  @Test("R-SET-1 -AbacusPreviewData opens the in-memory preview data, never a file")
  func previewData() throws {
    #expect(
      try choose(path: "/tmp/demo.sqlite", preview: true, remembered: Self.remembered, existing: [Self.remembered],
        defaultAllowed: false) == .previewData)
  }

  @Test("R-SET-1 -AbacusDatabasePath opens that file; the app's own database is not looked up")
  func demoPath() throws {
    #expect(
      try choose(path: "/tmp/demo.sqlite", remembered: Self.remembered, existing: [Self.remembered], defaultAllowed: false)
        == .demoFile(URL(filePath: "/tmp/demo.sqlite")))
  }

  @Test("R-SET-1 otherwise the remembered data folder's file when it exists, else the default")
  func appDatabase() throws {
    #expect(try choose(remembered: Self.remembered, existing: [Self.remembered]) == .appFile(Self.remembered))
    #expect(try choose(remembered: Self.remembered) == .appFile(Self.defaultFile))
    #expect(try choose() == .appFile(Self.defaultFile))
    #expect(try choose(path: "") == .appFile(Self.defaultFile))
  }
}
