import AbacusDomain
import AbacusFeatures
import SwiftUI

extension View {
  /// The main window's toolbar: "NBU rates · <day>" (R-FX-4), display-currency segmented
  /// control on the sections that use it (R-HOME-4) and "New transaction" (⌘N). Screens add their own items next to it.
  func shellToolbar() -> some View {
    modifier(ShellToolbar())
  }
}

struct ShellToolbar: ViewModifier {
  @Environment(AppModel.self) private var app

  func body(content: Content) -> some View {
    content.toolbar {
      ToolbarItem(placement: .automatic) {
        RatesAsOfLabel()
      }
      .sharedBackgroundVisibility(.hidden)

      // Only where amounts follow the display currency (R-HOME-4).
      if (app.section ?? .dashboard).usesDisplayCurrency {
        ToolbarItem(placement: .automatic) {
          DisplayCurrencyPicker()
        }
      }

      ToolbarItem(placement: .primaryAction) {
        Button {
          app.requestNewTransaction()
        } label: {
          Label("New transaction", systemImage: "plus")
            .labelStyle(.titleAndIcon)
        }
        .help("New transaction (⌘N)")
      }
    }
  }
}

/// "NBU rates · 21 Oct 2026"; an amber warning when the last fetch failed.
struct RatesAsOfLabel: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    HStack(spacing: 4) {
      if app.ratesStatus.isOffline {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help("Couldn't reach the rate service; the last known rates are used.")
      }
      Text(app.ratesAsOfLabel)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
  }
}

/// UAH / PLN / EUR / USD for every widget and total; remembered (R-HOME-4).
struct DisplayCurrencyPicker: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Picker(
      "Display currency",
      selection: Binding(get: { app.displayCurrency }, set: { app.setDisplayCurrency($0) })
    ) {
      ForEach(Currency.allCases, id: \.self) { currency in
        Text(currency.rawValue).tag(currency)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .help("Display currency")
  }
}
