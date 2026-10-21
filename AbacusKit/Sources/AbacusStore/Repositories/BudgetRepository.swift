import AbacusDomain
import Foundation
import SQLiteData

/// Monthly budget plans (R-BUD). A plan is in effect from its month until the next plan.
public struct SQLiteBudgetRepository: BudgetRepository {
  public let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  /// R-BUD-3: the latest plan with `effectiveMonth <= month`.
  public func plan(for month: Month) async throws -> (plan: BudgetPlan, allocations: [BudgetAllocation])? {
    let monthString = month.string
    return try await database.read { db in
      let latest = try BudgetPlan
        .where { $0.effectiveMonth.lte(monthString) }
        .order { $0.effectiveMonth.desc() }
        .limit(1)
        .fetchOne(db)
      guard let plan = latest else { return nil }
      let planID = plan.id
      let allocations = try BudgetAllocation.where { $0.planID.eq(planID) }.fetchAll(db)
      return (plan, allocations)
    }
  }

  /// R-BUD-3: saves `plan` effective from its month onward. Another plan for the same month is
  /// replaced; plans of earlier months stay (past months keep their limits), and so do explicit
  /// plans of later months. The plan's allocations are replaced by `allocations`.
  public func save(_ plan: BudgetPlan, allocations: [BudgetAllocation]) async throws {
    try await database.write { db in
      let planID = plan.id
      let month = plan.effectiveMonth
      try BudgetPlan.where { $0.effectiveMonth.eq(month) && $0.id.neq(planID) }.delete().execute(db)
      try BudgetPlan.upsert { BudgetPlan.Draft(plan) }.execute(db)
      try BudgetAllocation.where { $0.planID.eq(planID) }.delete().execute(db)
      let rows = allocations.map {
        BudgetAllocation(id: $0.id, planID: planID, categoryID: $0.categoryID, limitMinor: $0.limitMinor)
      }
      if !rows.isEmpty {
        try BudgetAllocation.insert { rows }.execute(db)
      }
    }
  }

  /// Every plan, oldest first (budget editor history).
  public func plans() async throws -> [BudgetPlan] {
    try await database.read { db in
      try BudgetPlan.order(by: \.effectiveMonth).fetchAll(db)
    }
  }
}
