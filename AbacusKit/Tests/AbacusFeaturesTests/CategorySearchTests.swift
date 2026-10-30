import AbacusDomain
import Foundation
import Testing

@testable import AbacusFeatures

@Suite("Category picker search (C34)")
struct CategorySearchTests {
  typealias Item = CategoryPickerItem<Int>

  // Food (Groceries, Zabka snacks), Transport (Taxi), Income: Salary (Bonus).
  static let items: [Item] = [
    Item(value: 1, title: "Food", section: "Expense"),
    Item(value: 2, title: "Groceries", isChild: true, section: "Expense"),
    Item(value: 3, title: "Żabka snacks", isChild: true, section: "Expense"),
    Item(value: 4, title: "Transport", section: "Expense"),
    Item(value: 5, title: "Taxi", isChild: true, section: "Expense"),
    Item(value: 6, title: "Salary", section: "Income"),
    Item(value: 7, title: "Bonus", isChild: true, section: "Income"),
  ]

  private func ids(_ query: String, _ items: [Item] = CategorySearchTests.items) -> [Int] {
    CategorySearch.hits(items, query: query).map(\.item.value)
  }

  @Test func emptyQueryReturnsEverything() {
    #expect(ids("") == [1, 2, 3, 4, 5, 6, 7])
    #expect(ids("   ") == [1, 2, 3, 4, 5, 6, 7])
  }

  @Test func parentMatchBringsAllChildren() {
    #expect(ids("food") == [1, 2, 3])
    #expect(ids("trans") == [4, 5])
  }

  @Test func childOnlyMatchComesUnderItsContextParent() {
    let hits = CategorySearch.hits(Self.items, query: "taxi")
    #expect(hits.map(\.item.value) == [4, 5])
    #expect(hits.map(\.isContext) == [true, false])
  }

  @Test func caseAndDiacriticsAreFolded() {
    #expect(ids("ZABKA") == [1, 3])
    #expect(ids("żabka") == [1, 3])
    #expect(ids("GROCERIES") == [1, 2])
  }

  @Test func whitespaceIsCollapsed() {
    #expect(ids("  zabka    snacks ") == [1, 3])
  }

  @Test func noMatchIsEmpty() {
    #expect(ids("zzz").isEmpty)
  }

  @Test func sectionsKeepOrderAndDropEmptyGroups() {
    let all = CategorySearch.groups(Self.items, query: "")
    #expect(all.map(\.heading) == ["Expense", "Income"])
    let income = CategorySearch.groups(Self.items, query: "bonus")
    #expect(income.map(\.heading) == ["Income"])
    #expect(income[0].hits.map(\.item.value) == [6, 7])
  }

  @Test func archivedAreHiddenUnlessSelected() {
    var items = Self.items
    items[2].isArchived = true
    #expect(ids("", items) == [1, 2, 4, 5, 6, 7])
    #expect(CategorySearch.hits(items, query: "", isSelected: { $0 == 3 }).map(\.item.value) == [1, 2, 3, 4, 5, 6, 7])
    #expect(CategorySearch.hits(items, query: "zabka").isEmpty)
  }

  @Test func childMatchDoesNotBorrowAParentOfAnotherSection() {
    let items = [
      Item(value: 1, title: "A", section: "Expense"),
      Item(value: 2, title: "Stray", isChild: true, section: "Income"),
    ]
    #expect(ids("stray", items) == [2])
  }

  @Test func rowsFromCategoriesFollowTheKindFilter() {
    let food = AbacusDomain.Category(name: "Food", kind: .expense)
    let salary = AbacusDomain.Category(name: "Salary", kind: .income)
    let both = CategoryPickerItem.items(from: [food, salary])
    #expect(both.map(\.section) == ["Expense", "Income"])
    #expect(CategoryPickerItem.items(from: [food, salary], kinds: [.income]).map(\.title) == ["Salary"])
  }
}
