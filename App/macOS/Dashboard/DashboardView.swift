import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Dashboard section (approved prototype group 1, R-HOME-1…6): the month selector shared by
/// the month widgets, then the widgets in the owner's order (`DashboardModel.layout`), each one
/// movable by drag and drop (R-HOME-6).
///
/// The shell passes the display currency (R-HOME-4) and handles a donut drill-down by opening
/// Transactions filtered to the slice's kind, category (nil: "Uncategorised") and month
/// (`TransactionFilters.drillDown(_:)`).
///
/// Debts (C14): pass the widget's view as `debts`; without it the Debts widget is not shown (its
/// place in the order is kept).
struct DashboardView: View {
  let displayCurrency: Currency
  let onDrillDown: (DashboardDrillDown.Target) -> Void
  /// The budget card's edit button: the shell opens Budget management (R-HOME-2).
  let onEditBudget: () -> Void
  /// The Debts widget (full width), when the app has one.
  let debts: AnyView?
  private let initiallyShowsAccounts: Bool
  @State private var model: DashboardModel
  /// Two half-width widgets per row (false at narrow widths: one per row).
  @State private var isWide = true
  /// The page itself takes the window's first focus (see `content`).
  @FocusState private var pageFocused: Bool

  /// Below this content width half-width widgets take a row each (two cards of 340 + spacing).
  static let twoColumnWidth: CGFloat = 696

  init(
    displayCurrency: Currency, dependencies: DashboardDependencies,
    debts: AnyView? = nil,
    onEditBudget: @escaping () -> Void = {},
    onDrillDown: @escaping (DashboardDrillDown.Target) -> Void
  ) {
    self.init(
      model: DashboardModel(dependencies: dependencies, displayCurrency: displayCurrency),
      displayCurrency: displayCurrency, debts: debts, onEditBudget: onEditBudget, onDrillDown: onDrillDown)
  }

  /// With a model the shell keeps, so the selected month survives switching sections.
  init(
    model: DashboardModel, displayCurrency: Currency, initiallyShowsAccounts: Bool = false,
    debts: AnyView? = nil,
    onEditBudget: @escaping () -> Void = {},
    onDrillDown: @escaping (DashboardDrillDown.Target) -> Void
  ) {
    self.displayCurrency = displayCurrency
    self.onDrillDown = onDrillDown
    self.onEditBudget = onEditBudget
    self.debts = debts
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
      #if DEBUG
        // `-AbacusWindowWidth/-AbacusWindowHeight`: snapshots at a narrow width (C13).
        DebugWindowSize.applyIfRequested()
      #endif
      model.setDisplayCurrency(displayCurrency)
      if model.phase == .idle { await model.load() }
    }
    .onChange(of: displayCurrency) { _, currency in model.setDisplayCurrency(currency) }
  }

  private var content: some View {
    ScrollViewReader { proxy in
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let warning = model.ratesWarning {
          DashboardNotice(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let missing = model.missingRatesText {
          DashboardNotice(text: missing, systemImage: "exclamationmark.circle.fill", tint: .orange)
        }
        DashboardMonthBar(model: model)
        DashboardWidgetGrid(
          widgets: visibleWidgets, columns: isWide ? 2 : 1,
          onMove: { widget, target in Task { await model.moveWidget(widget, to: target) } },
          onStep: { widget, step in Task { await model.moveWidget(widget, by: step, among: visibleWidgets) } },
          onReset: model.layout.isDefault ? nil : { Task { await model.resetLayout() } }
        ) { widget in
          widgetView(widget).id(widget)
        }
        .animation(.snappy, value: model.layout)
        HStack(alignment: .firstTextBaseline) {
          Text("\(model.ratesText). Month totals convert each amount at its day's rate; net worth uses the latest rate.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          if !model.layout.isDefault {
            Button("Reset layout") { Task { await model.resetLayout() } }
              .controlSize(.small)
              .help("Put the widgets back in their default order")
          }
        }
      }
      // With Full Keyboard Access on (System Settings › Keyboard navigation) the window gives its
      // first focus to a control and scrolls it into view; without a default it picked the last
      // control on the page ("Open Debts", "Reset layout"), so the dashboard opened scrolled to
      // the bottom. This invisible anchor at the very top (behind the content, taking no space)
      // takes that first focus, so the page always opens at the top; Tab moves on as before.
      .background(alignment: .top) {
        Color.clear
          .frame(width: 1, height: 1)
          .focusable()
          .focusEffectDisabled()
          .focused($pageFocused)
          .accessibilityHidden(true)
      }
      .onGeometryChange(for: Bool.self) { $0.size.width >= Self.twoColumnWidth } action: { isWide = $0 }
      .padding(20)
      .frame(maxWidth: 1180, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .defaultFocus($pageFocused, true)
    #if DEBUG
      // `-AbacusDashboardScrollTo <widget>`: snapshots of a widget below the fold (C14).
      .task {
        guard let id = UserDefaults.standard.string(forKey: "AbacusDashboardScrollTo"),
          let widget = DashboardWidget(rawValue: id)
        else { return }
        try? await Task.sleep(for: .seconds(1))
        proxy.scrollTo(widget, anchor: .bottom)
      }
    #endif
    }
  }

  /// The widgets in the remembered order that have something to show.
  private var visibleWidgets: [DashboardWidget] {
    model.layout.order.filter { widget in
      switch widget {
      case .netWorth: model.netWorth != nil
      case .budget, .incomeVsExpenses: true
      case .expenses: model.expenses != nil
      case .income: model.income != nil
      case .debts: debts != nil
      }
    }
  }

  @ViewBuilder
  private func widgetView(_ widget: DashboardWidget) -> some View {
    switch widget {
    case .netWorth:
      if let netWorth = model.netWorth {
        DashboardNetWorthCard(netWorth: netWorth, format: model.format, showsAccounts: initiallyShowsAccounts)
      }
    case .budget:
      DashboardBudgetCard(budget: model.budget, monthTitle: model.monthTitle, onEdit: onEditBudget)
    case .expenses:
      if let expenses = model.expenses {
        DashboardDonutCard(donut: expenses, monthTitle: model.monthTitle, selected: model.selectedSlice) { slice in
          if let target = model.select(slice) { onDrillDown(target) }
        }
      }
    case .income:
      if let income = model.income {
        DashboardDonutCard(donut: income, monthTitle: model.monthTitle, selected: model.selectedIncomeSlice) { slice in
          if let target = model.select(slice) { onDrillDown(target) }
        }
      }
    case .incomeVsExpenses:
      if let data = model.incomeVsExpenses {
        DashboardIncomeExpensesCard(
          data: data, format: model.format,
          canSelect: { $0 >= model.earliestMonth && $0 <= model.today.yearMonth }
        ) { month in
          Task { await model.show(month: month) }
        }
      }
    case .debts:
      if let debts { debts }
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

  /// "#RRGGBB" → a colour, the same mapping as every other screen (`CategoryColor`).
  static func color(hex: String) -> Color { CategoryColor.color(hex) }
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
  DashboardView(displayCurrency: .UAH, dependencies: .preview(), onDrillDown: { _ in })
    .frame(width: 1100, height: 1400)
}

#Preview("Full year, accounts shown") {
  DashboardView(
    model: DashboardModel(dependencies: .sample()), displayCurrency: .UAH, initiallyShowsAccounts: true,
    onDrillDown: { _ in }
  )
  .frame(width: 1100, height: 1600)
}

#Preview("Narrow, debts placeholder") {
  DashboardView(
    displayCurrency: .PLN, dependencies: .sample(),
    debts: AnyView(Text("Debts widget").frame(height: 120).dashboardCard()), onDrillDown: { _ in }
  )
  .frame(width: 640, height: 1400)
}

#Preview("Rates offline, dark") {
  DashboardView(displayCurrency: .PLN, dependencies: .sample(fetchFailed: true), onDrillDown: { _ in })
    .frame(width: 1100, height: 1400)
    .preferredColorScheme(.dark)
}
