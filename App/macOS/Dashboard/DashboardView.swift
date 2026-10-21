import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Dashboard section (approved prototype group 1, R-HOME-1…5): net worth with its monthly
/// chart, then the month selector shared by the budget and the expenses donut.
///
/// The shell passes the display currency (R-HOME-4) and handles a donut drill-down by opening
/// Transactions filtered to the category and month (`DashboardDrillDown.query`).
struct DashboardView: View {
  let displayCurrency: Currency
  let onDrillDown: (AbacusDomain.Category.ID, Month) -> Void
  private let initiallyShowsAccounts: Bool
  @State private var model: DashboardModel

  init(
    displayCurrency: Currency, dependencies: DashboardDependencies,
    onDrillDown: @escaping (AbacusDomain.Category.ID, Month) -> Void
  ) {
    self.init(
      model: DashboardModel(dependencies: dependencies, displayCurrency: displayCurrency),
      displayCurrency: displayCurrency, onDrillDown: onDrillDown)
  }

  /// With a model the shell keeps, so the selected month survives switching sections.
  init(
    model: DashboardModel, displayCurrency: Currency, initiallyShowsAccounts: Bool = false,
    onDrillDown: @escaping (AbacusDomain.Category.ID, Month) -> Void
  ) {
    self.displayCurrency = displayCurrency
    self.onDrillDown = onDrillDown
    self.initiallyShowsAccounts = initiallyShowsAccounts
    _model = State(initialValue: model)
  }

  var body: some View {
    Group {
      switch model.phase {
      case .failed(let message):
        ContentUnavailableView {
          Label("Dashboard unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try again") { Task { await model.load() } }
        }
      case .idle, .loading:
        ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        content
      }
    }
    .background(DashboardStyle.pageBackground)
    .navigationTitle("Dashboard")
    .task {
      model.setDisplayCurrency(displayCurrency)
      if model.phase == .idle { await model.load() }
    }
    .onChange(of: displayCurrency) { _, currency in model.setDisplayCurrency(currency) }
  }

  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let warning = model.ratesWarning {
          DashboardNotice(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let missing = model.missingRatesText {
          DashboardNotice(text: missing, systemImage: "exclamationmark.circle.fill", tint: .orange)
        }
        if let netWorth = model.netWorth {
          DashboardNetWorthCard(netWorth: netWorth, format: model.format, showsAccounts: initiallyShowsAccounts)
        }
        DashboardMonthBar(model: model)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
          DashboardBudgetCard(budget: model.budget, monthTitle: model.monthTitle)
          if let expenses = model.expenses {
            DashboardExpensesCard(expenses: expenses, monthTitle: model.monthTitle, selected: model.selectedSlice) { slice in
              if let target = model.select(slice) { onDrillDown(target.categoryID, target.month) }
            }
          }
        }
        Text("\(model.ratesText). Month totals convert each amount at its day's rate; net worth uses the latest rate.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(20)
      .frame(maxWidth: 1180, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

/// ‹ October 2026 › with the month note (R-HOME-5); next is disabled at the current month.
struct DashboardMonthBar: View {
  let model: DashboardModel

  var body: some View {
    HStack(spacing: 10) {
      Button {
        Task { await model.showPreviousMonth() }
      } label: {
        Image(systemName: "chevron.left").frame(width: 14, height: 14)
      }
      .disabled(!model.canShowPreviousMonth)
      .help("Previous month")
      .accessibilityLabel("Previous month")
      .keyboardShortcut(.leftArrow, modifiers: .command)

      Text(model.monthTitle)
        .font(.title3.weight(.semibold))
        .frame(minWidth: 140)
        .accessibilityAddTraits(.isHeader)

      Button {
        Task { await model.showNextMonth() }
      } label: {
        Image(systemName: "chevron.right").frame(width: 14, height: 14)
      }
      .disabled(!model.canShowNextMonth)
      .help("Next month")
      .accessibilityLabel("Next month")
      .keyboardShortcut(.rightArrow, modifiers: .command)

      Text(model.monthNote)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.bordered)
  }
}

/// A non-blocking warning line (R-FX-4, missing rates).
struct DashboardNotice: View {
  let text: String
  let systemImage: String
  let tint: Color

  var body: some View {
    Label {
      Text(text).foregroundStyle(.primary)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(tint)
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
  }
}

/// Shared look of the dashboard: white cards on the window background in light mode, raised
/// dark cards in dark mode.
enum DashboardStyle {
  static let pageBackground = Color(nsColor: .windowBackgroundColor)
  static let cardBackground = Color(nsColor: .controlBackgroundColor)

  static func color(_ status: LimitStatus) -> Color {
    switch status {
    case .ok: .accentColor
    case .near: .orange
    case .over: .red
    }
  }

  /// "#RRGGBB" → a colour; grey when it does not parse.
  static func color(hex: String) -> Color {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .gray }
    return Color(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

struct DashboardCardModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 20)
      .padding(.vertical, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashboardStyle.cardBackground, in: .rect(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
  }
}

extension View {
  func dashboardCard() -> some View { modifier(DashboardCardModifier()) }

  func dashboardCardTitle() -> some View {
    font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
  }
}

#Preview("Preview data") {
  DashboardView(displayCurrency: .UAH, dependencies: .preview(), onDrillDown: { _, _ in })
    .frame(width: 1100, height: 1000)
}

#Preview("Full year, accounts shown") {
  DashboardView(
    model: DashboardModel(dependencies: .sample()), displayCurrency: .UAH, initiallyShowsAccounts: true,
    onDrillDown: { _, _ in }
  )
  .frame(width: 1100, height: 1200)
}

#Preview("Rates offline, dark") {
  DashboardView(displayCurrency: .PLN, dependencies: .sample(fetchFailed: true), onDrillDown: { _, _ in })
    .frame(width: 1100, height: 1000)
    .preferredColorScheme(.dark)
}
