import AbacusDomain
import AbacusFX
import AbacusFeatures
import Charts
import SwiftUI

/// Exchange rates (approved prototype group 6, R-FX-2/4/5): updated label + Refresh rates in the
/// toolbar, offline banner, "Today's rates" next to "Manual rates".
struct RatesView: View {
  @Bindable var model: RatesModel
  /// Side by side when both sections fit (420 + 380 pt), stacked otherwise.
  @State private var isWide = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let message = model.offlineMessage {
          OfflineBanner(message: message) {
            Task { await model.refresh() }
          }
        }
        if isWide {
          HStack(alignment: .top, spacing: 20) {
            TodaysRatesSection(model: model).frame(maxWidth: .infinity)
            ManualRatesSection(model: model).frame(maxWidth: .infinity)
          }
        } else {
          VStack(alignment: .leading, spacing: 20) {
            TodaysRatesSection(model: model)
            ManualRatesSection(model: model)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onGeometryChange(for: Bool.self) { $0.size.width >= 860 } action: { isWide = $0 }
    .navigationTitle("Exchange rates")
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Text(model.updatedLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      .sharedBackgroundVisibility(.hidden)

      ToolbarItem(placement: .primaryAction) {
        Button {
          Task { await model.refresh() }
        } label: {
          Label(model.refreshLabel, systemImage: "arrow.clockwise")
            .labelStyle(.titleAndIcon)
        }
        .disabled(model.isRefreshing)
        .help("Refresh rates (⌘R)")
      }
    }
  }
}

/// "Couldn't reach the rate service. …" + Try again (R-FX-4). Non-blocking.
struct OfflineBanner: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Try again", action: retry)
        .buttonStyle(.link)
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.35)))
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Today's rates

struct TodaysRatesSection: View {
  @Bindable var model: RatesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Today's rates").font(.headline)
        Spacer()
        Picker("Show in", selection: $model.showIn) {
          ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
      }
      .frame(height: 28)

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
        GridRow {
          Text("Currency")
          Text("Rate").gridColumnAlignment(.trailing)
          Text("Day").gridColumnAlignment(.trailing)
          Text("30 days")
          Text("Source")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)

        ForEach(model.rows) { row in
          Divider().gridCellUnsizedAxes(.horizontal)
          RateRowView.gridRow(row)
        }
      }
      .padding(.horizontal, 12)
      .background(.background, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

      if model.rows.isEmpty && model.isLoaded {
        Text("No rates yet. Refresh rates to fetch them.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Text(RatesModel.ratesNote)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// One grid row of "Today's rates" (a direct child of the grid).
enum RateRowView {
  @ViewBuilder
  static func gridRow(_ row: RatesModel.Row) -> some View {
    GridRow {
      Text(row.currency.rawValue)
        .fontWeight(.semibold)
        .frame(minWidth: 50, alignment: .leading)
      Text(row.rateText)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
      Text(row.changeText)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(changeColor(row))
        .frame(minWidth: 64, alignment: .trailing)
      Sparkline(points: row.series)
        .frame(width: 120, height: 26)
        .accessibilityLabel("\(row.currency.rawValue) over the last 30 days")
      SourceBadge(text: row.badge, isManual: row.isManual)
        .frame(minWidth: 60, alignment: .leading)
    }
    .font(.body)
    .padding(.vertical, 9)
  }

  static func changeColor(_ row: RatesModel.Row) -> Color {
    switch row.trend {
    case .up: .green
    case .down: .red
    case .flat: .secondary
    }
  }
}

/// 30-day line, no axes (Swift Charts).
struct Sparkline: View {
  let points: [RatePoint]

  var body: some View {
    let values = points.map { NSDecimalNumber(decimal: $0.rate).doubleValue }
    let low = values.min() ?? 0
    let high = values.max() ?? 1
    let pad = high > low ? (high - low) * 0.1 : max(abs(high) * 0.01, 0.0001)
    Chart(Array(zip(points, values)), id: \.0.day) { point, value in
      LineMark(x: .value("Day", point.day.date()), y: .value("Rate", value))
        .interpolationMethod(.monotone)
        .lineStyle(StrokeStyle(lineWidth: 1.5))
        .foregroundStyle(.tint)
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartYScale(domain: (low - pad)...(high + pad))
    .chartLegend(.hidden)
  }
}

/// "NBU" / "Manual".
struct SourceBadge: View {
  let text: String
  let isManual: Bool

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .foregroundStyle(isManual ? Color.orange : Color.secondary)
      .background(Capsule().fill(isManual ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.12)))
  }
}

// MARK: - Manual rates

struct ManualRatesSection: View {
  @Bindable var model: RatesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Manual rates").font(.headline)
        .frame(height: 28)

      ForEach(model.overrideRows) { row in
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(row.pair).fontWeight(.semibold)
            Text(row.applies).font(.callout).foregroundStyle(.secondary)
            if !row.note.isEmpty {
              Text(row.note).font(.callout)
            }
          }
          Spacer()
          Button("Remove", role: .destructive) {
            Task { await model.removeOverride(row.id) }
          }
          .accessibilityLabel(row.removeLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
      }

      if model.overrideRows.isEmpty && model.isLoaded {
        Text(RatesModel.noOverridesText)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      AddManualRateForm(model: model)

      Text(RatesModel.manualNote)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// 1 [cur] = [rate] [cur] (fetched: …), On one day / From <day> until changed, note.
struct AddManualRateForm: View {
  @Bindable var model: RatesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Add a manual rate").fontWeight(.semibold)

      HStack(spacing: 6) {
        Text("1")
        CurrencyMenu(title: "From currency", selection: $model.formFrom)
        Text("=")
        TextField("Rate", text: $model.formRateText)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 100)
          .onSubmit(add)
        CurrencyMenu(title: "To currency", selection: $model.formTo)
        Text(model.fetchedHint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Picker("Applies", selection: $model.formMode) {
        HStack(spacing: 6) {
          Text("On one day")
          DatePicker("Day", selection: dayBinding(\.formOneDay), displayedComponents: .date)
            .labelsHidden()
            .disabled(model.formMode != .oneDay)
        }
        .tag(RatesModel.ApplyMode.oneDay)
        HStack(spacing: 6) {
          Text("From")
          DatePicker("From day", selection: dayBinding(\.formFromDay), displayedComponents: .date)
            .labelsHidden()
            .disabled(model.formMode != .fromDay)
          Text("until changed")
        }
        .tag(RatesModel.ApplyMode.fromDay)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()

      TextField("Note (optional), e.g. rate my bank charged", text: $model.formNote)

      HStack {
        if let error = model.formError ?? model.errorMessage {
          Text(error)
            .font(.callout)
            .foregroundStyle(.red)
        }
        Spacer()
        Button("Add manual rate", action: add)
          .buttonStyle(.borderedProminent)
          .disabled(!model.canAddOverride)
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
  }

  private func add() {
    Task { await model.addOverride() }
  }

  private func dayBinding(_ keyPath: ReferenceWritableKeyPath<RatesModel, Day>) -> Binding<Date> {
    Binding(
      get: { model[keyPath: keyPath].date() },
      set: { model[keyPath: keyPath] = Day($0) })
  }
}

struct CurrencyMenu: View {
  let title: String
  @Binding var selection: Currency

  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .fixedSize()
  }
}

#Preview("Rates") {
  let app = AppModel(environment: .preview(refreshDelay: .zero))
  NavigationStack {
    RatesView(model: app.rates)
  }
  .task { await app.load() }
  .frame(width: 1000, height: 700)
}

#Preview("Rates · offline") {
  let app = AppModel(environment: .preview(offline: true, refreshDelay: .zero))
  NavigationStack {
    RatesView(model: app.rates)
  }
  .task { await app.load() }
  .frame(width: 1000, height: 700)
}
