import AbacusDomain
import Foundation
import Testing

@testable import AbacusFeatures

@Suite("Account picker search (C37)")
struct AccountSearchTests {
  static let ids = (0..<7).map { _ in UUID() }
  static func item(_ n: Int, _ name: String, _ code: String, _ section: String?, archived: Bool = false) -> AccountPickerItem {
    AccountPickerItem(id: ids[n], name: name, currencyCode: code, section: section, isArchived: archived)
  }

  // Cash (Wallet EUR, Żabka UAH), Mono (Black UAH, Old card UAH archived), PKO (Personal PLN), ungrouped Piggy EUR.
  static let items: [AccountPickerItem] = [
    item(0, "Wallet", "EUR", "Cash"),
    item(1, "Żabka portfel", "UAH", "Cash"),
    item(2, "Black", "UAH", "Mono"),
    item(3, "Old card", "UAH", "Mono", archived: true),
    item(4, "Personal", "PLN", "PKO"),
    item(5, "Piggy", "EUR", nil),
  ]

  private func found(_ query: String, selected: Set<UUID> = [], excluding: Set<UUID> = []) -> [Int] {
    AccountSearch.items(Self.items, query: query, isSelected: { selected.contains($0) }, excluding: excluding)
      .map { item in Self.ids.firstIndex(of: item.id)! }
  }

  @Test func titleIsNameAndCurrency() {
    #expect(Self.items[0].title == "Wallet · EUR")
  }

  @Test func emptyQueryReturnsEverythingButArchived() {
    #expect(found("") == [0, 1, 2, 4, 5])
    #expect(found("  ") == [0, 1, 2, 4, 5])
  }

  @Test func matchesNameCaseInsensitively() {
    #expect(found("WALLET") == [0])
    #expect(found("pers") == [4])
  }

  @Test func matchesCurrencyCode() {
    #expect(found("uah") == [1, 2])
    #expect(found("eur") == [0, 5])
  }

  @Test func groupNameBringsTheWholeGroup() {
    #expect(found("cash") == [0, 1])
    #expect(found("mono") == [2])  // the archived member stays out
  }

  @Test func diacriticsAndWhitespaceAreFolded() {
    #expect(found("zabka") == [1])
    #expect(found("ŻABKA  portfel") == [1])
  }

  @Test func archivedIsExcludedUnlessSelected() {
    #expect(found("old").isEmpty)
    #expect(found("old", selected: [Self.ids[3]]) == [3])
    #expect(found("", selected: [Self.ids[3]]) == [0, 1, 2, 3, 4, 5])
  }

  @Test func exclusionDropsAnAccount() {
    #expect(found("", excluding: [Self.ids[0]]) == [1, 2, 4, 5])
    #expect(found("eur", excluding: [Self.ids[5]]) == [0])
    #expect(found("", selected: [Self.ids[0]], excluding: [Self.ids[0]]) == [1, 2, 4, 5])
  }

  @Test func groupsKeepOrderAndDropEmptyOnes() {
    let all = AccountSearch.groups(Self.items, query: "")
    #expect(all.map(\.heading) == ["Cash", "Mono", "PKO", nil])
    let eur = AccountSearch.groups(Self.items, query: "eur")
    #expect(eur.map(\.heading) == ["Cash", nil])
    #expect(AccountSearch.groups(Self.items, query: "zzz").isEmpty)
  }

  @Test func sectionsFilterKeepsSelectedAndDropsEmptyGroups() {
    let day = Date(timeIntervalSince1970: 0)
    func account(_ n: Int, _ name: String, _ currency: Currency) -> Account {
      Account(id: Self.ids[n], name: name, currency: currency, kind: .bank, openingDate: day)
    }
    let cash = AccountGroup(name: "Cash")
    let pko = AccountGroup(name: "PKO")
    let sections = [
      AccountPickerSection(group: cash, accounts: [account(0, "Wallet", .EUR), account(1, "Jar", .UAH)]),
      AccountPickerSection(group: pko, accounts: [account(4, "Personal", .PLN)]),
      AccountPickerSection(group: nil, accounts: [account(5, "Piggy", .EUR)]),
    ]
    #expect(AccountSearch.sections(sections, query: "") == sections)
    #expect(AccountSearch.sections(sections, query: "pko").map(\.title) == ["PKO"])
    #expect(AccountSearch.sections(sections, query: "eur").flatMap(\.accounts).map(\.name) == ["Wallet", "Piggy"])
    let kept = AccountSearch.sections(sections, query: "eur", isSelected: { $0 == Self.ids[4] })
    #expect(kept.map(\.title) == ["Cash", "PKO", nil])
    #expect(kept[0].accounts.map(\.name) == ["Wallet"])
  }
}
