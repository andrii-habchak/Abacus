import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import Testing

/// S1 (D54): every screen's model on a data set larger than the owner's (`LargeSampleData`:
/// 5,000 transactions, 50 accounts in 8 groups, 40 categories, 10 debts), loaded through
/// `AppSession.live` like the app. Prints timings; the budget is 150 ms per screen in release
/// builds (`swift test -c release`) and a generous bound in debug builds. Also times what a view
/// body reads (`rows`, `people`, …) so no body evaluation re-does a load's work.
@MainActor
@Suite("Large data set performance (S1)", .serialized)
struct LargeDataPerformanceTests {
  #if DEBUG
    static let loadBudget: Duration = .milliseconds(1_500)
    static let bodyBudget: Duration = .milliseconds(30)
  #else
    static let loadBudget: Duration = .milliseconds(150)
    static let bodyBudget: Duration = .milliseconds(5)
  #endif

  nonisolated static let today = Day(year: 2026, month: 10, day: 21)

  func session() async throws -> AppSession {
    let database = try LargeSampleData.database(today: Self.today)
    let session = AppSession.live(
      database: database, source: StubSource(rates: []), now: { Self.today.date() })
    await session.start()
    await session.waitForLaunchFetch()
    return session
  }

  func time(_ work: () async -> Void) async -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    await work()
    return clock.now - start
  }

  /// The slowest of `runs` evaluations of a body-read property.
  func bodyTime<T>(_ runs: Int = 20, _ read: () -> T) -> Duration {
    let clock = ContinuousClock()
    var worst: Duration = .zero
    for _ in 0..<runs {
      let start = clock.now
      _ = read()
      worst = max(worst, clock.now - start)
    }
    return worst
  }

  @Test("The large data set has the advertised size")
  func dataSetSize() async throws {
    let database = try LargeSampleData.database(today: Self.today)
    let counts = try await database.read { db in
      (
        try Account.fetchCount(db), try AccountGroup.fetchCount(db), try Txn.fetchCount(db),
        try AbacusDomain.Category.fetchCount(db), try Debt.fetchCount(db)
      )
    }
    #expect(counts.0 == 50 + 15, "50 own accounts plus 15 virtual debt accounts")
    #expect(counts.1 == 8)
    #expect(counts.2 >= 5_000)
    #expect(counts.3 >= 40)
    #expect(counts.4 == 10)
  }

  @Test("Every screen loads within budget on the large data set")
  func everyScreenLoads() async throws {
    let session = try await session()
    var report: [String] = []
    let loads: [(String, () async -> Void, () -> Bool)] = [
      ("dashboard", { await session.dashboard.load() }, { session.dashboard.phase == .loaded }),
      ("transactions", { await session.transactions.load() }, { session.transactions.errorMessage == nil }),
      ("accounts", { await session.accounts.load() }, { session.accounts.phase == .loaded }),
      ("categories", { await session.categories.load() }, { session.categories.phase == .loaded }),
      ("budget", { await session.budget.load() }, { session.budget.phase == .loaded }),
      ("events", { await session.events.load() }, { session.events.phase == .loaded }),
      ("rules", { await session.rules.load() }, { session.rules.phase == .loaded }),
      ("debts", { await session.debts.load() }, { session.debts.phase == .loaded }),
    ]
    for (name, load, loaded) in loads {
      await load()  // first load: caches warm
      let warm = await time(load)
      #expect(loaded(), "\(name) did not load")
      #expect(warm < Self.loadBudget, "\(name) took \(warm)")
      report.append("\(name) \(warm)")
    }
    print("Large data set, screen reloads: " + report.joined(separator: ", "))
    session.stop()
  }

  @Test("What view bodies read is cheap on the large data set")
  func bodyReadsAreCheap() async throws {
    let session = try await session()
    await session.accounts.load()
    await session.categories.load()
    await session.events.load()
    await session.rules.load()
    await session.debts.load()
    await session.budget.load()
    let reads: [(String, Duration)] = [
      ("accounts.rows", bodyTime { session.accounts.rows }),
      ("accounts.emptySearchMessage", bodyTime { session.accounts.emptySearchMessage }),
      ("accounts.canDrop", bodyTime { session.accounts.canDrop(session.accounts.rows[3].id, on: session.accounts.rows[1].id, position: .before) }),
      ("categories.rows", bodyTime { session.categories.rows }),
      ("events.rows", bodyTime { session.events.rows }),
      ("rules.rows", bodyTime { session.rules.rows }),
      ("debts.people", bodyTime { session.debts.people }),
      ("debts.selectedDetails", bodyTime { session.debts.selectedDetails }),
      ("debts.summary", bodyTime { session.debts.summary }),
      ("budget.rows", bodyTime { session.budget.rows }),
      ("transactions.accountSections", bodyTime { session.transactions.accountSections }),
    ]
    print("Large data set, body reads (worst of 20): " + reads.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    for (name, duration) in reads {
      #expect(duration < Self.bodyBudget, "\(name) took \(duration)")
    }
    session.stop()
  }
}
