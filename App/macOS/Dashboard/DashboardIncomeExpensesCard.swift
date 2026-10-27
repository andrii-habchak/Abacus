import AbacusDomain
import AbacusFeatures
import Charts
import SwiftUI

/// Income vs expenses (R-HOME-6): the twelve months ending at the selected month, an income and
/// an expenses bar per month and the net as a line. Hovering a month shows its figures under the
/// chart (highlight only); clicking a month shows it in the month selector (`onSelectMonth`),
/// which never leaves the dashboard.
struct DashboardIncomeExpensesCard: View {
  let data: DashboardIncomeExpenses
  let format: DashboardFormat
  /// Months the selector can show (nil: none); others aren't clickable.
  let canSelect: (Month) -> Bool
  let onSelectMonth: (Month) -> Void
  @State private var hovered: Month?

  static let incomeColor = Color.green
  static let expenseColor = Color.red.opacity(0.8)
  static let netColor = Color.primary

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if data.isEmpty {
        Text("No income or expenses in \(data.rangeText).")
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          chart
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    }
    .dashboardCard()
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Income vs expenses").dashboardCardTitle()
          .accessibilityAddTraits(.isHeader)
        Text(data.rangeText).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      figure("Income", data.incomeText, color: Self.incomeColor, mark: AnyView(swatch(Self.incomeColor)))
      figure("Expenses", data.expenseText, color: .primary, mark: AnyView(swatch(Self.expenseColor)))
      figure(
        "Net", data.netText, color: data.net.minorUnits < 0 ? .red : .primary,
        mark: AnyView(Capsule().fill(Self.netColor).frame(width: 12, height: 2)))
    }
  }

  private func swatch(_ color: Color) -> some View {
    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
  }

  private func figure(_ title: String, _ value: String, color: Color, mark: AnyView) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        mark
        Text(title).font(.caption).foregroundStyle(.secondary)
      }
      Text(value).font(.body.weight(.medium)).foregroundStyle(color).monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: Chart

  /// The month under the pointer, else the selected one.
  private var shown: DashboardIncomeExpenses.Bar? {
    if let hovered, let bar = data.bars.first(where: { $0.month == hovered }) { return bar }
    return data.bars.last
  }

  private var detail: String {
    guard let bar = shown else { return " " }
    return "\(bar.title): income \(bar.incomeText) · expenses \(bar.expenseText) · net \(bar.netText)"
  }

  private var domain: ClosedRange<Double> {
    let values = data.bars.flatMap { [double($0.income), double($0.expense), double($0.net)] }
    let low = min(0, values.min() ?? 0)
    let high = max(1, values.max() ?? 1)
    return low...(high + (high - low) * 0.05)
  }

  private var chart: some View {
    let domain = domain
    let shownMonth = shown?.month
    let labels = Dictionary(data.bars.map { ($0.month.string, $0) }, uniquingKeysWith: { first, _ in first })
    return Chart {
      ForEach(data.bars) { bar in
        if bar.month == shownMonth {
          RectangleMark(
            x: .value("Month", bar.month.string), yStart: .value("Low", domain.lowerBound),
            yEnd: .value("High", domain.upperBound), width: .ratio(0.96)
          )
          .foregroundStyle(Color.secondary.opacity(0.1))
        }
        BarMark(x: .value("Month", bar.month.string), y: .value("Amount", double(bar.income)), width: .ratio(0.36))
          .foregroundStyle(Self.incomeColor)
          .position(by: .value("Kind", "Income"))
          .cornerRadius(2)
          .accessibilityLabel("\(bar.title) income")
          .accessibilityValue(bar.incomeText)
        BarMark(x: .value("Month", bar.month.string), y: .value("Amount", double(bar.expense)), width: .ratio(0.36))
          .foregroundStyle(Self.expenseColor)
          .position(by: .value("Kind", "Expenses"))
          .cornerRadius(2)
          .accessibilityLabel("\(bar.title) expenses")
          .accessibilityValue(bar.expenseText)
      }
      ForEach(data.bars) { bar in
        LineMark(x: .value("Month", bar.month.string), y: .value("Net", double(bar.net)), series: .value("Series", "Net"))
          .foregroundStyle(Self.netColor)
          .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        PointMark(x: .value("Month", bar.month.string), y: .value("Net", double(bar.net)))
          .symbol {
            Circle()
              .fill(bar.month == shownMonth ? Self.netColor : DashboardStyle.cardBackground)
              .stroke(Self.netColor, lineWidth: 1.5)
              .frame(width: bar.month == shownMonth ? 8 : 5, height: bar.month == shownMonth ? 8 : 5)
          }
          .accessibilityLabel("\(bar.title) net")
          .accessibilityValue(bar.netText)
      }
      RuleMark(y: .value("Zero", 0))
        .foregroundStyle(Color.secondary.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 0.5))
    }
    .chartLegend(.hidden)
    .chartYScale(domain: domain)
    .chartXAxis {
      AxisMarks { value in
        AxisValueLabel {
          if let key = value.as(String.self), let bar = labels[key] {
            Text(bar.axisLabel)
              .fontWeight(bar.isSelected ? .semibold : .regular)
              .foregroundStyle(bar.isSelected ? Color.primary : Color.secondary)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(format.compact(Decimal(amount), data.currency))
          }
        }
      }
    }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle()
          .fill(.clear)
          .contentShape(.rect)
          .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered = month(at: location, proxy: proxy, geometry: geometry)
            case .ended: hovered = nil
            }
          }
          .onTapGesture { location in
            if let month = month(at: location, proxy: proxy, geometry: geometry), canSelect(month) {
              onSelectMonth(month)
            }
          }
      }
    }
    .help(hoveredHelp)
    .frame(height: 190)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(data.chartLabel)
  }

  private var hoveredHelp: String {
    guard let hovered, hovered != data.month, canSelect(hovered),
      let bar = data.bars.first(where: { $0.month == hovered })
    else { return "" }
    return "Show \(bar.title)"
  }

  private func month(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Month? {
    guard let frame = proxy.plotFrame else { return nil }
    let x = location.x - geometry[frame].origin.x
    guard let key: String = proxy.value(atX: x) else { return nil }
    return Month(key)
  }

  private func double(_ value: Money) -> Double { NSDecimalNumber(decimal: value.decimal).doubleValue }
}

#Preview("Income vs expenses, full year") {
  @Previewable @State var model = DashboardModel(dependencies: .sample())
  VStack {
    if let data = model.incomeVsExpenses {
      DashboardIncomeExpensesCard(data: data, format: model.format, canSelect: { _ in true }) { month in
        Task { await model.show(month: month) }
      }
    }
  }
  .padding()
  .frame(width: 900)
  .task { await model.load() }
}
