import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// C42: special letters and replacement characters in rule matching.
@Suite("Text folding in rules (C42)")
struct TextFoldingTests {
  private func hold(_ pattern: String, _ text: String, _ kind: RuleMatchKind = .contains) -> Bool {
    let rule = CategoryRule(pattern: pattern, matchKind: kind, categoryID: UUID())
    return RuleMatcher.conditionsHold(rule, for: RuleSubject(description: text))
  }

  @Test("Polish pangram folds to ASCII")
  func pangram() {
    let text = "Pchnąć w tę łódź jeża lub ośm skrzyń fig. ŻÓŁĆ GĘŚLĄ JAŹŃ"
    #expect(RulePattern.normalized(text) == "pchnac w te lodz jeza lub osm skrzyn fig. zolc gesla jazn")
  }

  @Test("other Latin letters without a decomposition")
  func otherLetters() {
    #expect(TextFolding.fold("Straße Ærø Œuvre Đồng Þór Øl") == "strasse aero oeuvre dong thor ol")
    #expect(TextFolding.fold("ZAKŁAD") == "zaklad")
  }

  @Test("ZUS: bank text with Ł/Ś/Ń matches the ASCII pattern and the reverse")
  func zus() {
    #expect(hold("ZAKLAD UBEZPIECZEN SPOLECZNYCH", "ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH"))
    #expect(hold("ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH", "ZAKLAD UBEZPIECZEN SPOLECZNYCH"))
    #expect(hold("ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH", "zakład ubezpieczeń społecznych"))
    #expect(hold("zaklad", "ZAKŁAD UBEZPIECZEŃ", .startsWith))
    #expect(hold("ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH", "ZAKLAD UBEZPIECZEN SPOLECZNYCH", .exactly))
    #expect(hold("URZAD SKARBOWY", "URZĄD SKARBOWY"))
  }

  @Test("a stored pattern with a special letter keeps matching the old text")
  func oldPatternsKeepWorking() {
    #expect(hold("społeczn", "SPOŁECZNYCH"))
    #expect(hold("łódź", "LODZ"))
  }

  @Test("a replacement character in the text matches one character")
  func replacementCharacter() {
    #expect(hold("URZAD SKARBOWY", "URZ\u{FFFD}D SKARBOWY"))
    #expect(hold("URZĄD SKARBOWY", "URZ\u{FFFD}D SKARBOWY"))
    #expect(hold("ZAKLAD UBEZPIECZEN SPOLECZNYCH", "ZAK\u{FFFD}AD UBEZPIECZE\u{FFFD} SPO\u{FFFD}ECZNYCH"))
    #expect(hold("URZAD", "URZ\u{FFFD}D SKARBOWY", .startsWith))
    #expect(hold("URZAD SKARBOWY", "URZ\u{FFFD}D SKARBOWY", .exactly))
    // Exactly one character per replacement character.
    #expect(!hold("URZAD SKARBOWY", "URZ\u{FFFD}\u{FFFD}D SKARBOWY"))
    #expect(!hold("URZAD SKARBOWY", "URZ\u{FFFD}X SKARBOWY"))
    #expect(hold("URZAD", "URZ\u{FFFD}D", .exactly))
  }

  @Test("guard: text that is mostly replacement characters does not match everything")
  func wildcardGuard() {
    #expect(!hold("ZUS", "\u{FFFD}\u{FFFD}\u{FFFD}"))
    #expect(!hold("ZUS", "Z\u{FFFD}\u{FFFD}"))
    #expect(hold("ZUS", "Z\u{FFFD}S"))
  }

  @Test("text without replacement characters is matched exactly as before")
  func plain() {
    #expect(hold("zus", "ZUS PŁATNOŚĆ"))
    #expect(!hold("zus", "ZU S"))
    #expect(!hold("zus", ""))
  }
}
