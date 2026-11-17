import AbacusDomain
import AbacusFeatures
import Charts
import SwiftUI

/// Colours of the Forecast page (prototype `N5-forecast`): blue lines for today's forecast and the
/// actual balance, orange for a past forecast and its gap band, red for the gap and zero.
enum ForecastStyle {
  static let actual = Color.accentColor
  static let past = Color(red: 0xE0 / 255, green: 0x86 / 255, blue: 0x1A / 255)
  static let gap = Color(red: 0xF2 / 255, green: 0x9D / 255, blue: 0x0A / 255)
  static let gapMarker = Color.red
}

/// The projection chart (R-REC-13) and, with a past forecast picked, the overlay (R-REC-19):
/// actual line, the snapshot's dashed forecast, today's lighter dashed forecast, a "Today"
/// marker and the gap band with its amount. Hover shows the day's values underneath.
struct ForecastChart: View {
  let model: ForecastModel
  @State private var hovered: Day?

  private enum Line: String {
    case actual = "Actual"
    case past = "Past forecast"
    case today = "Today’s forecast"
  }

  private struct Plot: Identifiable {
    let line: Line
    let day: Day
    let date: Date
    let value: Double
    var id: String { "\(line.rawValue)|\(day.string)" }
  }

  private struct Band: Identifiable {
    let date: Date
    let low: Double
    let high: Double
    var id: Date { date }
  }

  var body: some View {
    let data = chartData
    VStack(alignment: .leading, spacing: 6) {
      chart(data)
      Text(model.detail(for: hovered ?? model.today))
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(2)
    }
  }

  // MARK: Data

  private struct ChartData {
    var plots: [Plot] = []
    var band: [Band] = []
    var gap: (date: Date, actual: Double, forecast: Double, text: String)?
    var todayPoint: Double?
    var xDomain: ClosedRange<Date>
    var yDomain: ClosedRange<Double>
    var spansZero: Bool
  }

  private func date(_ day: Day) -> Date { day.date(calendar: model.format.calendar) }
  private func value(_ minor: Int64) -> Double { Double(minor) / 100 }

  private var chartData: ChartData {
    var plots: [Plot] = []
    var band: [Band] = []
    var gap: (date: Date, actual: Double, forecast: Double, text: String)?
    let currency = model.seriesCurrency
    let today = model.today
    var todayPoint: Double?
    var start = today
    var end = today.plusDays(model.horizonDays)
    if let overlay = model.overlay {
      for point in overlay.actual {
        plots.append(Plot(line: .actual, day: point.day, date: date(point.day), value: value(point.valueMinor)))
      }
      for point in overlay.forecast {
        plots.append(Plot(line: .past, day: point.day, date: date(point.day), value: value(point.valueMinor)))
      }
      let forecastByDay = Dictionary(overlay.forecast.map { ($0.day, $0.valueMinor) }, uniquingKeysWith: { a, _ in a })
      for point in overlay.actual {
        guard let f = forecastByDay[point.day] else { continue }
        let a = value(point.valueMinor)
        band.append(Band(date: date(point.day), low: min(a, value(f)), high: max(a, value(f))))
      }
      if let first = overlay.forecast.first?.day { start = min(start, first) }
      if let last = overlay.forecast.last?.day { end = max(end, last) }
      if let gapDay = overlay.gapDay, let a = overlay.actualAtGap, let f = overlay.forecastAtGap, let g = overlay.gapMinor {
        gap = (date(gapDay), value(a), value(f), "gap " + model.format.signed(g, currency))
      }
      todayPoint = overlay.actual.last.map { value($0.valueMinor) }
    }
    if let projection = model.projection {
      for point in projection.points {
        plots.append(Plot(line: .today, day: point.day, date: date(point.day), value: value(point.valueMinor)))
      }
      if todayPoint == nil { todayPoint = projection.now.map { value($0.valueMinor) } }
    }
    let values = plots.map(\.value)
    var low = values.min() ?? 0
    var high = values.max() ?? 1
    let pad = max((high - low) * 0.1, 10)
    let spansZero = low - pad < 0 && high + pad > 0
    low -= pad
    high += pad
    if spansZero || (low > 0 && low < pad * 2) { low = min(low, 0) }
    return ChartData(
      plots: plots, band: band, gap: gap, todayPoint: todayPoint, xDomain: date(start)...date(end),
      yDomain: low...high, spansZero: low < 0 && high > 0)
  }

  // MARK: Chart

  private func chart(_ data: ChartData) -> some View {
    let currency = model.seriesCurrency
    let hasOverlay = model.overlay != nil
    let todayDate = date(model.today)
    return Chart {
      ForEach(data.band) { band in
        AreaMark(x: .value("Day", band.date), yStart: .value("Low", band.low), yEnd: .value("High", band.high))
          .foregroundStyle(ForecastStyle.gap.opacity(0.18))
          .interpolationMethod(.linear)
      }
      if data.spansZero {
        RuleMark(y: .value("Zero", 0))
          .foregroundStyle(Color.red.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
      RuleMark(x: .value("Today", todayDate))
        .foregroundStyle(Color.secondary)
        .lineStyle(StrokeStyle(lineWidth: 1))
        .annotation(position: .top, alignment: .leading, spacing: 2) {
          Text("Today").font(.caption2).foregroundStyle(.secondary)
        }
      ForEach(data.plots) { plot in
        LineMark(x: .value("Day", plot.date), y: .value("Value", plot.value), series: .value("Line", plot.line.rawValue))
          .foregroundStyle(color(plot.line, hasOverlay: hasOverlay))
          .lineStyle(style(plot.line, hasOverlay: hasOverlay))
          .interpolationMethod(.stepEnd)
      }
      if let gap = data.gap {
        RuleMark(x: .value("Gap day", gap.date), yStart: .value("Actual", gap.actual), yEnd: .value("Forecast", gap.forecast))
          .foregroundStyle(ForecastStyle.gapMarker)
          .lineStyle(StrokeStyle(lineWidth: 2))
          .offset(x: 7)
          .annotation(position: .trailing, alignment: .center, spacing: 10) {
            Text(gap.text).font(.caption.weight(.semibold)).foregroundStyle(ForecastStyle.gapMarker)
          }
      }
      if let point = data.todayPoint {
        PointMark(x: .value("Day", todayDate), y: .value("Value", point))
          .symbol {
            Circle().fill(DashboardStyle.cardBackground).stroke(ForecastStyle.actual, lineWidth: 2).frame(width: 9, height: 9)
          }
      }
      if let hovered {
        RuleMark(x: .value("Hover", date(hovered)))
          .foregroundStyle(Color.primary.opacity(0.35))
      }
    }
    .chartXScale(domain: data.xDomain)
    .chartYScale(domain: data.yDomain)
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 7)) { value in
        AxisGridLine().foregroundStyle(.clear)
        AxisValueLabel {
          if let date = value.as(Date.self) {
            Text(model.format.day(Day(date, calendar: model.format.calendar)))
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(model.format.compact(Int64((amount * 100).rounded()), currency))
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
                let picked: Date = proxy.value(atX: location.x - geometry[frame].origin.x)
              else { return }
              let clamped = min(max(picked, data.xDomain.lowerBound), data.xDomain.upperBound)
              hovered = Day(clamped.addingTimeInterval(43_200), calendar: model.format.calendar)
            case .ended:
              hovered = nil
            }
          }
      }
    }
    .frame(height: 270)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Forecast chart")
  }

  private func color(_ line: Line, hasOverlay: Bool) -> Color {
    switch line {
    case .actual: ForecastStyle.actual
    case .past: ForecastStyle.past
    case .today: hasOverlay ? ForecastStyle.actual.opacity(0.5) : ForecastStyle.actual
    }
  }

  private func style(_ line: Line, hasOverlay: Bool) -> StrokeStyle {
    switch line {
    case .actual: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
    case .past: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [6, 4])
    case .today: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: hasOverlay ? [2, 4] : [6, 4])
    }
  }
}
