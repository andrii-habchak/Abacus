import AbacusDomain
import AbacusFeatures
import SwiftUI

/// "Upcoming (30 days)" (R-REC-11, prototype `N5-forecast` dashboard): status chip, money out /
/// in / net in the display currency, up to six occurrences (overdue first), "N more · rates as of
/// … · transfers not counted" and "Open Upcoming". Without any item: one line and "Set up".
struct DashboardUpcomingCard: View {
  let model: UpcomingModel
  let displayCurrency: Currency
  var onOpen: () -> Void = {}

  var body: some View {
    let data = model.dashboard
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Upcoming (30 days)").dashboardCardTitle()
        Spacer()
        if data.hasItems {
          UpcomingTextChip(
            text: data.statusText, tint: data.overdueCount > 0 ? UpcomingPalette.negative : .secondary)
        }
      }
      if model.phase != .loaded {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
      } else if !data.hasItems {
        HStack(spacing: 8) {
          Text("No scheduled items. Set up your bills in Upcoming.").font(.callout).foregroundStyle(.secondary)
          Button("Set up", action: onOpen).controlSize(.small)
        }
      } else {
        HStack(alignment: .bottom, spacing: 20) {
          figure("Money out", data.outText, UpcomingPalette.negative)
          figure("Money in", data.inText, UpcomingPalette.positive)
          figure("Net", data.netText, .primary)
        }
        if data.rows.isEmpty {
          Text("Nothing due in the next 30 days.").font(.callout).foregroundStyle(.secondary)
        } else {
          VStack(spacing: 0) {
            ForEach(data.rows) { row in
              rowView(row)
              if row.id != data.rows.last?.id { Divider() }
            }
          }
        }
        HStack {
          Text(data.footnote).font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Open Upcoming", action: onOpen).controlSize(.small)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .dashboardCard()
    .onChange(of: displayCurrency, initial: true) { _, currency in model.displayCurrency = currency }
    .task { if model.phase == .idle { await model.load() } }
  }

  private func figure(_ title: String, _ text: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(text).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        .lineLimit(1).minimumScaleFactor(0.7)
    }
  }

  private func rowView(_ row: DashboardUpcoming.Row) -> some View {
    HStack(spacing: 10) {
      UpcomingTile(initial: row.initial, hex: row.colorHex)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.title).lineLimit(1)
        Text(row.accountText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if row.isOverdue {
        UpcomingTextChip(text: row.whenText, tint: UpcomingPalette.negative)
      } else {
        Text(row.whenText).font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .trailing, spacing: 1) {
        Text(row.amountText).fontWeight(.semibold).monospacedDigit()
          .foregroundStyle(row.isIncome ? UpcomingPalette.positive : .primary)
        if let converted = row.convertedText {
          Text(converted).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .frame(minWidth: 90, alignment: .trailing)
    }
    .padding(.vertical, 6)
  }
}
