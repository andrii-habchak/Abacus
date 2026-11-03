import AbacusDomain
import AbacusStore
import SQLiteData

/// Where the app's rates come from. Until the package lets AbacusMCP depend on AbacusFX
/// (`RateTable`), only same-currency amounts convert; see docs/status/N2.md.
public enum LiveRates {
  public static let source: RateSource = { _ in NoRates() }
}
