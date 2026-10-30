import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Transactions screen (approved prototype 2, R-LIST-1…6): filter bar, rows grouped by day
/// with the day's net, nested attached records, footer totals in the display currency.
///
/// The owner of the window keeps `model` alive (e.g. `@State`) so filters survive switching
/// sections. The page search sits full width above the filters (R-MGMT-11); the
/// display-currency control and "New transaction" belong to the shell.
struct TransactionsView: View {
  @Bindable var model: TransactionsViewModel
  /// From the shell's display-currency control (R-HOME-4).
  var displayCurrency: Currency
  /// Selection changed (click, arrow keys); nil when nothing is selected.
  var onSelect: (Txn.ID?) -> Void
  /// Double-click or Return on a row: open it in the editor.
  var onOpen: ((Txn.ID) -> Void)? = nil

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        PageSearchField(text: $model.filters.search, prompt: "Search description, note")
          .padding(.horizontal, TxnMetrics.horizontalPadding)
          .padding(.top, 12)
        TransactionFilterBar(model: model)
      }
      .background(TxnPalette.barBackground)
      Divider()
      TransactionColumnHeader()
        .padding(.horizontal, TxnMetrics.horizontalPadding)
        .padding(.vertical, 8)
      Divider()
      list
      Divider()
      TransactionsFooter(content: model.content)
        .background(TxnPalette.barBackground)
    }
    .navigationTitle("Transactions")
    .sheet(
      isPresented: Binding(
        get: { model.debtDraft != nil },
        set: { if !$0 { model.cancelConvertToDebt() } })
    ) {
      if let draft = model.debtDraft {
        DebtLinkSheet(
          initial: draft, saveTitle: "Transfer", onCancel: { model.cancelConvertToDebt() },
          onSave: { saved in Task { await model.saveConvertToDebt(saved) } })
      }
    }
    .onChange(of: displayCurrency, initial: true) { _, currency in
      model.displayCurrency = currency
    }
    .onChange(of: model.selection) { _, selection in
      onSelect(selection)
    }
    .task(id: model.query) {
      // Short pause so typing in the search field does not fetch on every keystroke.
      if !model.rows.isEmpty || model.filters.hasActiveFilters {
        try? await Task.sleep(for: .milliseconds(150))
        if Task.isCancelled { return }
      }
      await model.refresh()
      #if DEBUG || ABACUS_PROBE
        TransactionsDebugLaunch.apply(to: model)
      #endif
    }
  }

  @ViewBuilder
  private var list: some View {
    if model.content.isEmpty {
      VStack {
        Spacer()
        if let error = model.errorMessage {
          Text(error).foregroundStyle(.secondary)
        } else if !model.isLoading {
          Text("No transactions match these filters.")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(selection: $model.selection) {
        // One flat ForEach (day header, rows, attached lines): a nested one costs SwiftUI about
        // 0.5 ms per row on every appended page (C28, measured).
        ForEach(model.content.items) { item in
          switch item {
          case .header(let header):
            TransactionDayHeader(day: header)
              .listRowInsets(rowInsets(vertical: 0))
              .selectionDisabled()
          case .row(let row):
            TransactionRowView(row: row)
              .tag(row.id)
              .listRowInsets(rowInsets(vertical: 4))
              .onAppear { model.rowAppeared(row.id) }
          case .line(let line):
            TransactionLineView(line: line)
              .listRowInsets(rowInsets(vertical: 2))
              .selectionDisabled()
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .id(model.loadedQuery)
      .contextMenu(forSelectionType: Txn.ID.self) { ids in
        // R-DEBT-11/19: an expense or income becomes a transfer to a person's debt account in
        // place; such a transfer can be turned back.
        if ids.count == 1, let id = ids.first, model.canConvertToDebt(id) {
          Button("Transfer to Debt Account…") {
            Task { await model.beginConvertToDebt(id) }
          }
        }
        if ids.count == 1, let id = ids.first, model.canUnlinkTransfer(id) {
          Button("Undo Transfer to Debt") {
            Task { await model.unlinkTransfer(id) }
          }
        }
      } primaryAction: { ids in
        if let id = ids.first { onOpen?(id) }
      }
    }
  }

  private func rowInsets(vertical: CGFloat) -> EdgeInsets {
    EdgeInsets(
      top: vertical, leading: TxnMetrics.horizontalPadding - 8, bottom: vertical,
      trailing: TxnMetrics.horizontalPadding - 8)
  }
}

/// Count, income, expenses, net in the display currency (R-LIST-5).
struct TransactionsFooter: View {
  let content: TransactionListContent

  var body: some View {
    HStack(spacing: 20) {
      Text(content.totals.countLabel)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      HStack(spacing: 4) {
        Text("Income")
        Text(content.incomeText).fontWeight(.semibold).foregroundStyle(TxnPalette.inflow)
      }
      HStack(spacing: 4) {
        Text("Expenses")
        Text(content.expenseText).fontWeight(.semibold)
      }
      HStack(spacing: 4) {
        Text("Net")
        Text(content.netText)
          .fontWeight(.semibold)
          .foregroundStyle(content.totals.net.minorUnits >= 0 ? TxnPalette.inflow : TxnPalette.negative)
      }
      Text(note)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .font(.system(size: 13))
    .monospacedDigit()
    .lineLimit(1)
    .padding(.horizontal, TxnMetrics.horizontalPadding)
    .padding(.vertical, 12)
  }

  private var note: String {
    let base = "Converted at each day's NBU rate"
    switch content.totals.unconverted {
    case 0: return base
    case 1: return base + " · 1 amount without a rate left out"
    case let n: return base + " · \(n) amounts without a rate left out"
    }
  }
}

// MARK: - Previews

#Preview("Last 30 days") {
  TransactionsPreviewHost(model: .preview(displayCurrency: .PLN))
}

#Preview("Filtered") {
  var filters = TransactionFilters()
  filters.categoryIDs = [PreviewData.id(201)]
  filters.types = [.expense]
  return TransactionsPreviewHost(model: .preview(displayCurrency: .UAH, filters: filters))
}

#Preview("Empty") {
  TransactionsPreviewHost(model: .preview(filters: TransactionFilters(search: "nothing like this")))
}

/// Hosts the screen like the shell does (split view with a toolbar) for previews.
struct TransactionsPreviewHost: View {
  @State var model: TransactionsViewModel
  @State private var currency: Currency

  init(model: TransactionsViewModel) {
    _model = State(initialValue: model)
    _currency = State(initialValue: model.displayCurrency)
  }

  var body: some View {
    NavigationStack {
      TransactionsView(model: model, displayCurrency: currency, onSelect: { _ in })
        .toolbar {
          Picker("Display currency", selection: $currency) {
            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
        }
    }
    .frame(width: 1040, height: 760)
  }
}

#if DEBUG || ABACUS_PROBE
  /// Debug builds only, for UI checks on a scratch database: `-AbacusTransactionsEvent <name>`
  /// opens the list as that event's "Show N transactions" does, `-AbacusTransactionsSearch <text>`
  /// fills the page search, `-AbacusTransactionsTypes expense,income` sets the type toggles.
  @MainActor
  enum TransactionsDebugLaunch {
    private static var applied = false

    static func apply(to model: TransactionsViewModel) {
      guard !applied else { return }
      applied = true
      let defaults = UserDefaults.standard
      if let name = defaults.string(forKey: "AbacusTransactionsEvent"),
        let event = model.reference.events.first(where: { $0.name == name })
      {
        model.filters = .event(event)
      }
      if let search = defaults.string(forKey: "AbacusTransactionsSearch") { model.filters.search = search }
      if let types = defaults.string(forKey: "AbacusTransactionsTypes") {
        model.filters.types = Set(types.split(separator: ",").compactMap { TxnType(rawValue: String($0)) })
      }
      // `-AbacusTransactionsDebt <person|ANY>` (use with `-AbacusLoadLargeSampleData YES`): applies a
      // debt's "Show transactions" filter 10 s after launch; `-AbacusTransactionsDebtRemove YES` removes
      // it again 3 s later. With `-AbacusHangWatch YES` a `HANG <ms>` line shows how long the main
      // thread was blocked (C24: it was minutes before the list was keyed by the loaded query).
      if let person = defaults.string(forKey: "AbacusTransactionsDebt") {
        let remove = defaults.bool(forKey: "AbacusTransactionsDebtRemove")
        Task {
          try? await Task.sleep(for: .seconds(10))  // after the sample data is loaded
          await model.load()
          await model.loadDebtOptions()
          func say(_ text: String) { FileHandle.standardError.write(Data("DEBTFILTER \(text)\n".utf8)) }
          guard let debt = model.debtOptions.first(where: { person == "ANY" || $0.name == person }) else {
            return say("no such debt")
          }
          // Like "Show transactions" of a debt: every date.
          if let shown = await model.filters(showingDebt: debt.id) { model.filters = shown }
          say("applied")
          guard remove else { return }
          try? await Task.sleep(for: .seconds(3))
          model.toggleDebt(debt.id)
          say("removed")
        }
      }
      TransactionsPerfProbe.run(model: model)
      DebugWindowSize.applyIfRequested()
    }
  }

  /// Debug builds only: `-AbacusWindowWidth <points>` (and `-AbacusWindowHeight`) resize the
  /// main window, to check layouts at a narrow width in a snapshot.
  @MainActor
  enum DebugWindowSize {
    static func applyIfRequested() {
      let defaults = UserDefaults.standard
      let width = defaults.double(forKey: "AbacusWindowWidth")
      guard width > 0 else { return }
      let height = defaults.double(forKey: "AbacusWindowHeight")
      for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
        var frame = window.frame
        frame.size.width = width
        if height > 0 { frame.size.height = height }
        window.setFrame(frame, display: true)
      }
    }
  }

  /// Debug builds only (C28): `-AbacusTransactionsAllDates YES` switches to "All dates" 6 s after
  /// launch, then jumps the scroller to 50 %, 95 %, 10 % and 100 % and switches the type filter,
  /// printing `PERF <step> <ms>` (wall time until the main thread answers promptly again; use with
  /// `-AbacusHangWatch YES` for `HANG` lines). Scratch databases only.
  @MainActor
  enum TransactionsPerfProbe {
    static func run(model: TransactionsViewModel) {
      guard UserDefaults.standard.bool(forKey: "AbacusTransactionsAllDates") else { return }
      Task { @MainActor in
        func say(_ text: String) { FileHandle.standardError.write(Data("PERF \(text)\n".utf8)) }
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        /// Until the main thread has answered 3 short sleeps in a row without delay.
        func settle() async {
          var calm = 0
          while calm < 3 {
            let t = clock.now
            try? await Task.sleep(for: .milliseconds(10))
            calm = ms(clock.now - t) < 40 ? calm + 1 : 0
          }
        }
        func scrollView() -> NSScrollView? {
          func find(_ view: NSView) -> NSScrollView? {
            if let table = view as? NSTableView { return table.enclosingScrollView }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
          }
          for window in NSApp.windows { if let content = window.contentView, let found = find(content) { return found } }
          return nil
        }
        try? await Task.sleep(for: .seconds(6))
        await settle()
        var start = clock.now
        model.filters.dateRange = TransactionFilters.allDates
        while model.loadedQuery?.fromDay != Day(year: 1900, month: 1, day: 1) { try? await Task.sleep(for: .milliseconds(5)) }
        say("all dates: rows loaded after \(ms(clock.now - start)) ms (\(model.rows.count) of \(model.content.totals.count))")
        await settle()
        say("all dates: first rows on screen and responsive after \(ms(clock.now - start)) ms")
        for fraction in [0.5, 0.95, 0.1, 1.0] {
          guard let scroll = scrollView(), let document = scroll.documentView else { say("no table"); break }
          start = clock.now
          let y = max(0, (document.frame.height - scroll.contentView.bounds.height) * fraction)
          scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
          scroll.reflectScrolledClipView(scroll.contentView)
          await settle()
          say("scroller jump to \(Int(fraction * 100)) %: responsive after \(ms(clock.now - start)) ms (document \(Int(document.frame.height)) pt, \(model.rows.count) rows loaded)")
        }
        // Paging: keep scrolling to the end; each jump should load the next page.
        for step in 1...6 {
          guard let scroll = scrollView(), let document = scroll.documentView else { break }
          start = clock.now
          scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
          scroll.reflectScrolledClipView(scroll.contentView)
          await settle()
          try? await Task.sleep(for: .milliseconds(300))
          say("to the end, step \(step): responsive after \(ms(clock.now - start)) ms; \(model.rows.count) of \(model.summary.count) rows loaded")
        }
        start = clock.now
        model.filters.types = [.expense]
        while model.loadedQuery?.types != [.expense] { try? await Task.sleep(for: .milliseconds(5)) }
        await settle()
        say("filter change (expense only): responsive after \(ms(clock.now - start)) ms")
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
      }
    }
  }
#endif
