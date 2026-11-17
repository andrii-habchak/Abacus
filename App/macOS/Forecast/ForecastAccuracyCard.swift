import AbacusDomain
import AbacusFeatures
import SwiftUI

/// "Accuracy per scheduled item" (R-REC-20): per item paid of all, on-time share, average day
/// shift and average amount deviation, missed/skipped chips, "Update amount to X"; Details lists
/// the item's occurrences with expected vs actual day and amount.
struct ForecastAccuracyCard: View {
  @Bindable var model: ForecastModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Accuracy per scheduled item").dashboardCardTitle().accessibilityAddTraits(.isHeader)
        Spacer()
        if let snapshot = model.selectedSnapshot {
          Picker("Scope", selection: $model.accuracyScope) {
            Text("Since \(model.format.day(snapshot.takenDay))").tag(ForecastModel.AccuracyScope.sinceSnapshot)
            Text("All time").tag(ForecastModel.AccuracyScope.allTime)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        } else {
          Text("All time").font(.caption).foregroundStyle(.secondary)
        }
      }
      if let accuracy = model.accuracy {
        Text(overall(accuracy.overall)).font(.caption).foregroundStyle(.secondary)
        if accuracy.items.isEmpty {
          Text("No paid, skipped or missed occurrences yet.").font(.callout).foregroundStyle(.secondary)
            .padding(.vertical, 6)
        } else {
          table(accuracy)
        }
      }
      if let error = model.actionError {
        Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
      }
      Text(
        "Built from resolved occurrences (matched, skipped or missed), so it works even before a first snapshot exists. Expected values are the item’s amount and day at the time."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .dashboardCard()
  }

  private func overall(_ summary: AccuracySummary) -> String {
    var text = "Overall: \(summary.paid) paid"
    if let share = summary.onTimeShare { text += ", \(Int((share * 100).rounded())) % on time (within a day)" }
    text += ", \(summary.skipped) skipped, \(summary.missed) missed"
    if let deviation = summary.averageAbsDeviationPercent {
      text += ", amounts off by \(model.format.percent(deviation)) on average"
    }
    return text + "."
  }

  private func table(_ accuracy: ForecastAccuracy) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
      GridRow {
        Text("Item")
        Text("Paid")
        Text("On time")
        Text("Avg. day shift")
        Text("Avg. amount Δ")
        Text("")
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.vertical, 6)
      Divider()
      ForEach(accuracy.items) { row in
        itemRow(row)
        if model.expandedItems.contains(row.itemID) {
          GridRow {
            occurrences(row).gridCellColumns(6)
          }
        }
        Divider()
      }
    }
  }

  @ViewBuilder
  private func itemRow(_ row: ItemAccuracy) -> some View {
    let summary = row.summary
    let currency = model.currency(of: row.item)
    GridRow {
      HStack(spacing: 6) {
        Text(row.item?.payee ?? "Deleted item").fontWeight(.medium).lineLimit(1)
        if summary.missed > 0 { chip("\(summary.missed) missed", tint: .red) }
        if summary.skipped > 0 { chip("\(summary.skipped) skipped", tint: .secondary) }
        if let amount = row.suggestedAmountMinor, row.item != nil {
          Button {
            Task { await model.applySuggestion(itemID: row.itemID) }
          } label: {
            Text("Update amount to \(model.format.money(amount, currency))")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .tint(.orange)
          .help("Set the item’s amount to the latest paid amount; past occurrences keep theirs.")
        }
      }
      .gridColumnAlignment(.leading)
      Text("\(summary.paid) of \(row.rows.count)").monospacedDigit()
      Text(summary.onTimeShare.map { "\(Int(($0 * 100).rounded())) %" } ?? "—").monospacedDigit()
      Text(dayShift(row)).monospacedDigit()
      Text(summary.averageAbsDeviationPercent.map { model.format.percent($0) } ?? "—")
        .monospacedDigit()
        .foregroundStyle((summary.averageAbsDeviationPercent ?? 0) > ForecastAccuracy.suggestionThresholdPercent ? Color.red : Color.primary)
      Button(model.expandedItems.contains(row.itemID) ? "Hide" : "Details") { model.toggleExpanded(row.itemID) }
        .controlSize(.small)
        .accessibilityValue(model.expandedItems.contains(row.itemID) ? "Expanded" : "Collapsed")
        .gridColumnAlignment(.trailing)
    }
    .font(.callout)
    .padding(.vertical, 8)
  }

  private func dayShift(_ row: ItemAccuracy) -> String {
    guard let shift = model.averageDayShift(row.rows) else { return "—" }
    if shift < 0.05 { return "on the day" }
    return "±" + shift.formatted(.number.precision(.fractionLength(1))) + " d"
  }

  private func chip(_ text: String, tint: Color) -> some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .foregroundStyle(tint)
      .background(tint.opacity(0.14), in: .capsule)
  }

  private func occurrences(_ row: ItemAccuracy) -> some View {
    let format = model.format
    let currency = model.currency(of: row.item)
    return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
      GridRow {
        Text("Expected day")
        Text("Actual day")
        Text("Δ days")
        Text("Expected")
        Text("Actual")
        Text("Δ")
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      if row.rows.isEmpty {
        GridRow { Text("No occurrences in this period.").foregroundStyle(.secondary).gridCellColumns(6) }
      }
      ForEach(row.rows) { occurrence in
        GridRow {
          Text(occurrence.expectedDay.map(format.longDay) ?? occurrence.occurrence.expectedDay)
          actualDay(occurrence)
          Text(occurrence.dayDelta.map(format.dayShift) ?? "—")
          Text(format.money(occurrence.occurrence.expectedAmountMinor, currency))
          Text(occurrence.occurrence.actualAmountMinor.map { format.money($0, currency) } ?? "—")
          Text(occurrence.amountDeltaPercent.map(format.signedPercent) ?? "—")
            .foregroundStyle((occurrence.amountDeltaMinor ?? 0) != 0 ? Color.red : Color.primary)
        }
        .font(.caption)
        .monospacedDigit()
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
    .padding(.bottom, 8)
  }

  @ViewBuilder
  private func actualDay(_ occurrence: OccurrenceAccuracy) -> some View {
    switch occurrence.occurrence.status {
    case .paid: Text(occurrence.actualDay.map(model.format.longDay) ?? "—")
    case .skipped: Text("Skipped").foregroundStyle(.secondary)
    case .missed: Text("Missed").foregroundStyle(.red)
    }
  }
}
