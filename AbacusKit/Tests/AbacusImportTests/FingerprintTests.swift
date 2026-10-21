import AbacusDomain
import AbacusImport
import AbacusTestSupport
import Foundation
import Testing

@Suite("Import contracts")
struct FingerprintTests {
  @Test("R-IMP-3: Saldo fingerprints use the transaction id")
  func saldo() {
    #expect(Fingerprint.saldo(transactionID: "1001") == "saldo:1001")
  }

  @Test("R-IMP-3: PKO fingerprints are stable, ASCII and short enough for CloudKit")
  func pko() {
    let account = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let a = Fingerprint.pko(accountID: account, parts: ["2026-01-14", "2026-01-13", "-15.89", "+1150.37", "Tytuł: x"])
    let b = Fingerprint.pko(accountID: account, parts: ["2026-01-14", "2026-01-13", "-15.89", "+1150.37", "Tytuł: x"])
    #expect(a == b)
    #expect(a.hasPrefix("pko:"))
    let isASCII = a.allSatisfy { $0.isASCII }
    #expect(isASCII)
    #expect(a.count < 255)
  }

  @Test("Synthetic fixtures are bundled")
  func fixturesBundled() throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/saldo/README", withExtension: "md"))
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("Real samples are found when present", .tags(.realData), .enabled(if: RealSamples.has(prefix: "saldo")))
  func realSamples() throws {
    let url = try #require(RealSamples.file(prefix: "saldo"))
    #expect(FileManager.default.isReadableFile(atPath: url.path))
  }
}
