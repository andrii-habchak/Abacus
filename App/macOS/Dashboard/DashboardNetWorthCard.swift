import AbacusDomain
import AbacusFeatures
import Charts
import SwiftUI

/// Net worth (R-HOME-1): today's figure, the change since the previous month end, assets and
/// liabilities, a month-end line chart with hover, and the per-account breakdown on demand:
/// account groups with the sum of their accounts, the accounts indented beneath (R-MGMT-9).
struct DashboardNetWorthCard: View {
  let netWorth: DashboardNetWorth
  let format: DashboardFormat
  @State private var showsAccounts: Bool
  @State private var hovered: Day?

  init(netWorth: DashboardNetWorth, format: DashboardFormat, showsAccounts: Bool = false) {
    self.netWorth = netWorth
    self.format = format
    var expanded = showsAccounts
    #if DEBUG
      // UI reviews (in-app snapshot): `-AbacusNetWorthExpanded YES` opens the breakdown.
      if UserDefaults.standard.bool(forKey: "AbacusNetWorthExpanded") { expanded = true }
    #endif
    _showsAccounts = State(initialValue: expanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      VStack(alignment: .leading, spacing: 6) {
        chart
        Text(shownPoint?.detail ?? " ")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      if showsAccounts { accounts }
    }
    .dashboardCard()
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .bottom, spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Net worth").dashboardCardTitle()
          .accessibilityAddTraits(.isHeader)
        Text(netWorth.totalText)
          .font(.system(size: 34, weight: .semibold))
          .monospacedDigit()
          .contentTransition(.numericText())
        if let change = netWorth.changeText {
          Text(change)
            .font(.callout.weight(.medium))
            .foregroundStyle((netWorth.change?.minorUnits ?? 0) < 0 ? Color.red : Color.green)
        }
        if !netWorth.isComplete {
          Label("Leaves out accounts without an exchange rate", systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 28) {
        figure("Assets", netWorth.assetsText, color: .primary)
        figure("Liabilities", netWorth.liabilitiesText, color: .red)
        if let debts = netWorth.debtsText { figure("Debts (included)", debts, color: .secondary) }
      }

      Button(showsAccounts ? "Hide accounts" : "Show accounts") {
        withAnimation(.snappy) { showsAccounts.toggle() }
      }
      .controlSize(.small)
      .accessibilityValue(showsAccounts ? "Expanded" : "Collapsed")
    }
  }

  private func figure(_ title: String, _ value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.body.weight(.medium)).foregroundStyle(color).monospacedDigit()
    }
  }

  // MARK: Chart

  /// Points sit at evenly spaced positions, as in the prototype (the last one is today).
  private struct Plot: Identifiable {
    let point: DashboardNetWorth.Point
    let index: Int
    let value: Double
    /// Consecutive points with values; a month without rates breaks the line.
    let segment: Int
    var id: Day { point.day }
  }

  private var plots: [Plot] {
    var segment = 0
    var result: [Plot] = []
    for (index, point) in netWorth.points.enumerated() {
      guard let value = point.value else {
        segment += 1
        continue
      }
      result.append(Plot(point: point, index: index, value: double(value.decimal), segment: segment))
    }
    return result
  }

  private var shownPoint: DashboardNetWorth.Point? {
    if let hovered, let point = netWorth.points.first(where: { $0.day == hovered }) { return point }
    return netWorth.points.last
  }

  private var range: ClosedRange<Double> {
    guard let range = netWorth.valueRange else { return 0...1 }
    return double(range.lowerBound)...double(range.upperBound)
  }

  private var chart: some View {
    let plots = plots
    let range = range
    let points = netWorth.points
    let indices = Array(points.indices)
    let span = range.upperBound - range.lowerBound
    let gridValues = [range.lowerBound + span * 0.1, range.lowerBound + span / 2, range.upperBound - span * 0.1]
    let shown = shownPoint?.day
    return Chart(plots) { plot in
      AreaMark(
        x: .value("Month", plot.index), yStart: .value("Base", range.lowerBound), yEnd: .value("Net worth", plot.value),
        series: .value("Segment", plot.segment)
      )
      .foregroundStyle(Color.accentColor.opacity(0.08))
      LineMark(x: .value("Month", plot.index), y: .value("Net worth", plot.value), series: .value("Segment", plot.segment))
        .foregroundStyle(Color.accentColor)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      PointMark(x: .value("Month", plot.index), y: .value("Net worth", plot.value))
        .symbol {
          let isShown = plot.point.day == shown
          Circle()
            .fill(isShown ? Color.accentColor : DashboardStyle.cardBackground)
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: isShown ? 10 : 6, height: isShown ? 10 : 6)
        }
        .accessibilityLabel(plot.point.detail)
    }
    .chartXScale(domain: 0...max(1, points.count - 1), range: .plotDimension(padding: 20))
    .chartYScale(domain: range)
    .chartXAxis {
      AxisMarks(values: indices) { value in
        AxisValueLabel(centered: false, anchor: .top) {
          if let index = value.as(Int.self), points.indices.contains(index) {
            Text(points[index].axisLabel)
              .fontWeight(points[index].day == shown ? .semibold : .regular)
              .foregroundStyle(points[index].day == shown ? Color.primary : Color.secondary)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: gridValues) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(format.compact(Decimal(amount), netWorth.currency))
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
            case .active(let location):
              guard let frame = proxy.plotFrame,
                let position: Double = proxy.value(atX: location.x - geometry[frame].origin.x)
              else { return }
              let index = min(max(Int(position.rounded()), 0), points.count - 1)
              hovered = points.indices.contains(index) ? points[index].day : nil
            case .ended:
              hovered = nil
            }
          }
      }
    }
    .frame(height: 172)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(netWorth.chartLabel)
  }

  // MARK: Accounts

  private var accounts: some View {
    VStack(alignment: .leading, spacing: 8) {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
        Divider()
        ForEach(netWorth.breakdown) { row in
          GridRow {
            Text(row.name)
              .fontWeight(row.level == .group ? .semibold : .medium)
              .padding(.leading, row.level == .groupedAccount ? 16 : 0)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.detail).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.balanceText)
              .foregroundStyle(row.isNegative ? Color.red : Color.primary)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.convertedText)
              .fontWeight(row.level == .group ? .semibold : .regular)
              .foregroundStyle(row.level == .group ? (row.isNegative ? Color.red : Color.primary) : Color.secondary)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .monospacedDigit()
          .accessibilityElement(children: .combine)
          Divider()
        }
      }
      .font(.callout)
      Text("Archived accounts are not counted. Liabilities are subtracted.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .transition(.opacity)
  }

  private func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
}

#Preview("Net worth, full year") {
  @Previewable @State var model = DashboardModel(dependencies: .sample())
  VStack {
    if let netWorth = model.netWorth {
      DashboardNetWorthCard(netWorth: netWorth, format: model.format, showsAccounts: true)
    }
  }
  .padding()
  .frame(width: 900)
  .task { await model.load() }
}
