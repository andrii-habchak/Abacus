import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The dashboard Debts widget (R-DEBT-6): "Owed to you" / "You owe" in the display currency,
/// then people with open balances, largest first, per currency. Half width (owner). Reads `DashboardModel.debts`
/// (it follows the display currency and rates); "Open Debts" goes to the Debts tab.
struct DashboardDebtsCard: View {
  let model: DashboardModel
  var onOpen: () -> Void = {}
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
        HStack(alignment: .top, spacing: 20) {
          figure("Owed to you", debts.owedToMeText, color: DebtStyle.owedToMe)
          figure("You owe", debts.iOweText, color: DebtStyle.iOwe)
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
  }

  private func figure(_ title: String, _ value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.semibold)).foregroundStyle(color).monospacedDigit()
    }
  }

  /// One person, compact enough for a half-width card: the name (and the ≈ sum in the display
  /// currency when there are several currencies) on the left, each currency's balance stacked
  /// on the right.
  private func row(_ person: DashboardDebts.Person) -> some View {
    HStack(alignment: .top, spacing: 10) {
      DebtAvatar(name: person.name)
      VStack(alignment: .leading, spacing: 2) {
        Text(person.name).lineLimit(1).truncationMode(.tail)
        if let converted = person.convertedText {
          Text(converted).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .layoutPriority(1)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 4) {
        ForEach(person.balances) { balance in
          VStack(alignment: .trailing, spacing: 0) {
            Text(balance.amountText).font(.callout.weight(.semibold)).monospacedDigit()
              .foregroundStyle(balance.owesMe ? DebtStyle.owedToMe : DebtStyle.iOwe)
            Text(balance.directionText).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      .fixedSize()
    }
    .padding(.vertical, 6)
  }
}
