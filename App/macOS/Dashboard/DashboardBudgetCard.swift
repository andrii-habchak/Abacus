import AbacusDomain
import AbacusFeatures
import SwiftUI

/// Monthly budget (R-HOME-2, R-BUD-1…3): spent of total, remaining and % used, a status badge,
/// per-category bars (blue ok, amber ≥ 90 %, red over) and the unallocated row.
struct DashboardBudgetCard: View {
  /// nil when no plan is in effect for the month.
  let budget: DashboardBudget?
  let monthTitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Monthly budget").dashboardCardTitle()
          .accessibilityAddTraits(.isHeader)
        Spacer()
        if let budget { badge(budget) }
      }
      if let budget {
        summary(budget)
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          ForEach(budget.rows) { row in self.row(row) }
        }
      } else {
        Text("No budget for \(monthTitle).")
          .foregroundStyle(.secondary)
        Text("Set a monthly total and category limits in Budget.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .dashboardCard()
  }

  private func badge(_ budget: DashboardBudget) -> some View {
    let tint: Color = budget.overCount == 0 ? .green : .red
    return Text(budget.badgeText)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .foregroundStyle(tint)
      .background(tint.opacity(0.14), in: Capsule())
  }

  private func summary(_ budget: DashboardBudget) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(budget.spentText)
          .font(.system(size: 26, weight: .semibold))
          .monospacedDigit()
        Text(budget.limitText)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      DashboardBar(fraction: budget.barFraction, tint: DashboardStyle.color(budget.status), height: 8)
        .accessibilityLabel("Budget used")
        .accessibilityValue(budget.remainingText)
      Text(budget.remainingText)
        .font(.callout)
        .monospacedDigit()
      if let note = budget.currencyNote {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func row(_ row: DashboardBudget.Row) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(row.name)
          .fontWeight(.medium)
          .foregroundStyle(row.status == .over ? Color.red : Color.primary)
        Text(row.amountsText)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Text(row.noteText)
          .fontWeight(row.status == .ok ? .regular : .semibold)
          .foregroundStyle(noteColor(row.status))
      }
      .font(.callout)
      .monospacedDigit()
      DashboardBar(fraction: row.barFraction, tint: DashboardStyle.color(row.status))
        .accessibilityLabel(row.name)
        .accessibilityValue("\(row.amountsText), \(row.noteText)")
    }
  }

  private func noteColor(_ status: LimitStatus) -> Color {
    switch status {
    case .ok: .secondary
    case .near: .orange
    case .over: .red
    }
  }
}

/// A spending bar that keeps its ok / near / over colour in inactive windows too (a linear
/// `ProgressView` turns grey there, which would hide the status).
struct DashboardBar: View {
  let fraction: Double
  let tint: Color
  var height: CGFloat = 6

  var body: some View {
    Capsule()
      .fill(Color.secondary.opacity(0.18))
      .overlay(alignment: .leading) {
        GeometryReader { geometry in
          Capsule()
            .fill(tint)
            .frame(width: geometry.size.width * min(1, max(0, fraction)))
        }
      }
      .frame(height: height)
      .accessibilityElement()
  }
}

#Preview("Budget, over in August") {
  @Previewable @State var model = DashboardModel(dependencies: .sample(), displayCurrency: .PLN)
  DashboardBudgetCard(budget: model.budget, monthTitle: model.monthTitle)
    .padding()
    .frame(width: 520)
    .task {
      await model.load()
      await model.show(month: Month(year: 2026, month: 8))
    }
}

#Preview("No budget") {
  DashboardBudgetCard(budget: nil, monthTitle: "October 2026")
    .padding()
    .frame(width: 520)
}
