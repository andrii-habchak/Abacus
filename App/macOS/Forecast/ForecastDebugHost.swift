#if DEBUG
  import AbacusDomain
  import AbacusFeatures
  import SwiftUI

  /// UI reviews only: `-AbacusForecastDemo YES` with `-AbacusDatabasePath <scratch file>` shows the
  /// Forecast tab on that file (seeded with synthetic scheduled items and past snapshots) until
  /// the Upcoming section hosts it. Never used on the owner's database (no path, no view).
  struct ForecastDebugHost: View {
    let displayCurrency: Currency
    @State private var dependencies: ForecastDependencies?
    @State private var loaded = false

    var body: some View {
      Group {
        if let dependencies {
          ForecastView(dependencies: dependencies, displayCurrency: displayCurrency)
        } else if loaded {
          ContentUnavailableView("Forecast demo needs -AbacusDatabasePath", systemImage: "chart.line.uptrend.xyaxis")
        } else {
          ProgressView()
        }
      }
      .navigationTitle("Upcoming")
      .task {
        dependencies = await ForecastDependencies.demo(
          databasePath: UserDefaults.standard.string(forKey: "AbacusDatabasePath"))
        loaded = true
      }
    }

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "AbacusForecastDemo") }
  }
#endif
