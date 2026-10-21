import AbacusDomain
import Foundation

/// Synthetic NBU rates for the rates screen's previews: every weekday of the five weeks up to
/// `PreviewData.today`, ending at the preview data set's rates (PLN 11.30, EUR 48.50, USD 41.60
/// UAH) with a small deterministic wobble. Never real data (R-NF-6).
public enum PreviewRates {
  public static let today = PreviewData.today

  /// When the preview rates were "fetched": today 09:00.
  public static var lastUpdate: Date {
    Calendar.current.date(byAdding: .hour, value: 9, to: today.date())!
  }

  /// `dayBefore`: the previous official day's rate relative to `end` (the day change shown).
  private static let shapes: [(Currency, end: Double, drift: Double, wobble: Double, dayBefore: Double)] = [
    (.PLN, 11.30, 0.25, 0.020, 0.9979),
    (.EUR, 48.50, 0.40, 0.120, 1.0025),
    (.USD, 41.60, 0.30, 0.030, 0.9991),
  ]

  public static let fxRates: [FXRate] = {
    let calendar = Calendar.current
    let start = today.adding(days: -40)
    var days: [Day] = []
    var day = start
    while day <= today {
      let weekday = calendar.component(.weekday, from: day.date())
      if weekday != 1 && weekday != 7 { days.append(day) }
      day = day.adding(days: 1)
    }
    var rates: [FXRate] = []
    var n = 7000
    for (index, day) in days.enumerated() {
      let remaining = Double(days.count - 1 - index)
      let progress = remaining / Double(max(days.count - 1, 1))
      for shape in shapes {
        n += 1
        let value: Double =
          switch remaining {
          case 0: shape.end
          case 1: shape.end * shape.dayBefore
          default: shape.end - shape.drift * progress + shape.wobble * sin(Double(index) * 1.7)
          }
        let rate = Decimal(string: String(format: "%.4f", value))!
        rates.append(
          FXRate(
            id: PreviewData.id(n), day: day.string, base: shape.0, quote: .UAH,
            rateE8: RateScale.scaled(rate), provider: "NBU", fetchedAt: lastUpdate))
      }
    }
    return rates
  }()

  /// "1 EUR = 48.20 UAH, on 15 Oct only — rate my bank charged for the Lyon hotel".
  public static let overrides: [FXOverride] = [
    FXOverride(
      id: PreviewData.id(7901), base: .EUR, quote: .UAH, rateE8: RateScale.scaled(Decimal(string: "48.20")!),
      fromDay: "2026-10-15", untilDay: "2026-10-15", note: "Rate my bank charged for the Lyon hotel")
  ]

  public static func store() -> InMemoryRateStore {
    InMemoryRateStore(rates: fxRates, overrides: overrides)
  }

  public static func service(store: any RateStore, offline: Bool = false, delay: Duration = .milliseconds(900))
    -> PreviewRatesService
  {
    PreviewRatesService(
      store: store, status: RatesStatus(autoRefresh: true, lastUpdate: lastUpdate, latestDay: today),
      offline: offline, delay: delay)
  }
}
