import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The dashboard Debts widget (R-DEBT-6, R-DEBT-21): "You lent" (negative, red) / "You borrowed"
/// (positive, green) in the display currency, then people with open balances, largest first, per
/// currency; right-click a person for Edit, Show transactions, Mark settled, Delete. Half width
/// (owner). Reads `DashboardModel.debts` (it follows the display currency and rates); "Open Debts"
/// goes to the Debts tab, and so does Edit (the dialog lives there).
struct DashboardDebtsCard: View {
  let model: DashboardModel
  /// The Debts tab's model: the menu actions run through it.
  let debts: DebtsModel
  var onOpen: () -> Void = {}
  @State private var deleteTarget: DebtDeleteTarget?
  /// At most this many people; the rest are counted.
  var limit = 6

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Debts").dashboardCardTitle()
        Spacer()
        Button("Open Debts", action: onOpen)
          .buttonStyle(.link)
          .controlSize(.small)
      }
      if let debts = model.debts {
        VStack(alignment: .leading, spacing: 2) {
          Text(debts.isApproximate ? "≈ total" : "Total").font(.caption).foregroundStyle(.secondary)
          if let text = debts.totalText {
            Text(text).font(.title3.weight(.semibold)).monospacedDigit()
              .foregroundStyle(DebtStyle.color(stored: debts.total?.minorUnits))
          } else {
            Text("No rate").font(.title3).foregroundStyle(.secondary)
              .help("A rate to the display currency is missing; refresh the rates")
          }
        }
        if debts.isEmpty {
          Text("No open debts.").font(.callout).foregroundStyle(.secondary)
        } else {
          let shown = Array(debts.people.prefix(limit))
          VStack(spacing: 0) {
            ForEach(shown) { person in
              row(person)
              if person.id != shown.last?.id { Divider() }
            }
          }
          if debts.people.count > limit {
            Text("and \(debts.people.count - limit) more").font(.caption).foregroundStyle(.secondary)
          }
        }
      } else {
        Text("No debts yet.").font(.callout).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .dashboardCard()
    .confirmDebtDelete($deleteTarget) { id in Task { await debts.deleteDebt(id) } }
  }

  /// One person, compact enough for a half-width card: the name on the left, ONE main figure (the
  /// total in the display currency) on the right, and for several currencies a small caption with
  /// the per-currency amounts (R-DEBT-21).
  private func row(_ person: DashboardDebts.Person) -> some View {
    HStack(alignment: .top, spacing: 10) {
      DebtAvatar(name: person.name)
      Text(person.name).lineLimit(1).truncationMode(.tail)
        .layoutPriority(1)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        if let text = person.totalText {
          Text((person.isApproximate ? "≈ " : "") + text).font(.callout.weight(.semibold)).monospacedDigit()
            .foregroundStyle(DebtStyle.color(stored: person.total?.minorUnits))
        } else {
          Text("No rate").font(.callout).foregroundStyle(.secondary)
        }
        if let secondary = person.secondaryText {
          Text(secondary).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .fixedSize()
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .contextMenu {
      // Widget people are open with a non-zero balance, so "Mark settled" is offered but disabled
      // until the balance is zero (R-DEBT-5).
      DebtContextMenu(
        model: debts, debtID: person.debtID, actions: .init(isSettled: false, canToggleSettled: false),
        onEdit: {
          Task {
            await debts.edit(debtID: person.debtID)
            onOpen()
          }
        },
        onDelete: { deleteTarget = DebtDeleteTarget(id: person.debtID, name: person.name) })
    }
  }
}
