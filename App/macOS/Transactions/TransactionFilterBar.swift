import AbacusDomain
import AbacusFeatures
import SwiftUI

/// Date · Categories · Accounts · Debts · Types · Event (· Import) … Clear filters · sort: ONE row of
/// dropdown buttons, no chips (C28, approved prototype 2 otherwise, R-LIST-2/3). Every button that
/// is filtering has the same blue outline and a summary label ("5 accounts", "Debt: Alex"); a
/// single value is removed by un-ticking it inside its menu. When the window is too narrow the
/// labels are shortened and the row scrolls sideways; it never wraps into a second line.
///
/// Each menu lists only the values that have rows under all the OTHER filters (cascading filters,
/// `TransactionsViewModel.facetCounts`); a value that is ticked stays in its menu and is marked
/// when it has no rows left.
struct TransactionFilterBar: View {
  @Bindable var model: TransactionsViewModel
  @State private var open: Popover?
  @State private var debtSearch = ""

  enum Popover: Hashable { case date, categories, accounts, debts, types, event }

  /// Below this width the full labels do not fit next to each other.
  private static let compactBelow: CGFloat = 1_120
  private static let rowHeight: CGFloat = 28

  var body: some View {
    GeometryReader { proxy in
      let compact = proxy.size.width < Self.compactBelow
      ScrollView(.horizontal, showsIndicators: false) {
        row(labels: compact ? model.compactLabels : model.fullLabels)
          .frame(minWidth: proxy.size.width - 2 * TxnMetrics.horizontalPadding, alignment: .leading)
          .padding(.horizontal, TxnMetrics.horizontalPadding)
          .frame(minHeight: proxy.size.height)
      }
    }
    .frame(height: Self.rowHeight + 20)
  }

  private func row(labels: FilterBarLabels) -> some View {
    HStack(spacing: 8) {
      chip(.date, active: model.filters.isDateFiltered, label: labels.date, systemImage: "calendar")
      chip(.categories, active: model.filters.isCategoryFiltered, label: labels.categories)
      chip(.accounts, active: !model.filters.accountIDs.isEmpty, label: labels.accounts)
      if model.offersDebtFilter {
        chip(.debts, active: model.filters.isDebtFiltered, label: labels.debts)
      }
      chip(.types, active: model.filters.isTypeFiltered, label: labels.types)
      chip(.event, active: model.filters.eventID != nil, label: labels.event)
      if model.filters.importBatch != nil {
        importChip(label: labels.importFile)
      }
      Spacer(minLength: 12)
      if model.filters.hasActiveFilters {
        Button("Clear filters") { model.clearFilters() }
          .buttonStyle(.plain)
          .foregroundStyle(TxnPalette.link)
          .font(.system(size: 13))
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, 6)
      }
      sortButton(label: labels.sort)
    }
    .frame(height: Self.rowHeight)
  }

  // MARK: Buttons

  private func chip(_ popover: Popover, active: Bool, label: String, systemImage: String? = nil) -> some View {
    Button {
      open = open == popover ? nil : popover
    } label: {
      HStack(spacing: 6) {
        if let systemImage { Image(systemName: systemImage).font(.system(size: 12)) }
        Text(label).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .fixedSize()
    }
    .buttonStyle(TxnChipStyle(isActive: active))
    .popover(isPresented: isOpen(popover), arrowEdge: .bottom) { content(for: popover) }
  }

  /// "Import: <file> · <date>" (R-IMP-6, C33): a single closable chip like the debt one used to be,
  /// with no menu; the × removes only the import filter, the other filters stay.
  private func importChip(label: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "square.and.arrow.down").font(.system(size: 12))
      Text(label).lineLimit(1).truncationMode(.middle)
      Button {
        model.clearImportFilter()
      } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
      }
      .buttonStyle(.plain)
      .help("Show all transactions, not only this import")
      .accessibilityLabel("Remove the import filter")
    }
    .fixedSize()
    .modifier(TxnChipLook(isActive: true))
    .accessibilityElement(children: .contain)
  }

  private func isOpen(_ popover: Popover) -> Binding<Bool> {
    Binding(get: { open == popover }, set: { if !$0, open == popover { open = nil } })
  }

  private func sortButton(label: String) -> some View {
    Button {
      model.filters.newestFirst.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
        Text(label)
      }
      .fixedSize()
    }
    .buttonStyle(TxnChipStyle(isActive: false))
    .accessibilityLabel(
      model.filters.newestFirst
        ? "Sorted newest first. Switch to oldest first" : "Sorted oldest first. Switch to newest first")
  }

  // MARK: Popovers

  @ViewBuilder
  private func content(for popover: Popover) -> some View {
    switch popover {
    case .date: datePopover
    case .categories: categoriesPopover
    case .accounts: accountsPopover
    case .debts: debtsPopover
    case .types: typesPopover
    case .event: eventPopover
    }
  }

  /// "12" in the menu line, or an orange "no rows" when the ticked value has none left.
  @ViewBuilder
  private func countLabel(_ count: Int?, impossible: Bool) -> some View {
    if impossible {
      Text("no rows")
        .font(.system(size: 11))
        .foregroundStyle(.orange)
        .help("No transaction has this value under the other filters")
    } else if let count {
      Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  private func emptyNote(_ text: String) -> some View {
    Text(text).foregroundStyle(.secondary).padding(.vertical, 4)
  }

  private var datePopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(TransactionFilters.Preset.allCases) { preset in
        Button(preset.title) {
          model.filters.dateRange = .preset(preset)
          open = nil
        }
        .buttonStyle(TxnMenuItemStyle(isChosen: model.filters.dateRange == .preset(preset)))
      }
      Button("All dates") {
        model.filters.dateRange = TransactionFilters.allDates
        open = nil
      }
      .buttonStyle(TxnMenuItemStyle(isChosen: model.filters.dateRange == TransactionFilters.allDates))
      Divider().padding(.vertical, 6)
      Text("Custom range")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
      HStack(spacing: 8) {
        dayField("From", day: model.dateRange.lowerBound) { model.filters.setCustomRange(from: $0, to: model.dateRange.upperBound) }
        dayField("To", day: model.dateRange.upperBound) { model.filters.setCustomRange(from: model.dateRange.lowerBound, to: $0) }
      }
      .padding(.horizontal, 8)
      .padding(.top, 6)
      .padding(.bottom, 4)
    }
    .padding(6)
    .frame(width: 250)
  }

  private func dayField(_ title: String, day: Day, set: @escaping (Day) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 12))
      DatePicker(
        title,
        selection: Binding(get: { day.date() }, set: { set(Day($0)) }),
        displayedComponents: .date
      )
      .labelsHidden()
      .datePickerStyle(.field)
    }
  }

  private var categoriesPopover: some View {
    let entries = model.categoryMenu
    return ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        if model.showsUncategorisedOption {
          Toggle(
            isOn: Binding(
              get: { model.filters.includeUncategorised },
              set: { _ in model.toggleUncategorised() })
          ) {
            HStack(spacing: 8) {
              Circle().fill(TxnPalette.tile(model.reference.uncategorisedColor)).frame(width: 8, height: 8)
              Text(TransactionsViewModel.uncategorisedTitle).fontWeight(.medium)
              Spacer(minLength: 8)
              countLabel(model.uncategorisedCount, impossible: model.isUncategorisedImpossible)
            }
          }
          .toggleStyle(.checkbox)
          .padding(.vertical, 3)
          if !entries.isEmpty { Divider().padding(.vertical, 4) }
        }
        if entries.isEmpty && !model.showsUncategorisedOption {
          emptyNote("No categories under the other filters.")
        }
        ForEach(entries) { entry in
          Toggle(
            isOn: Binding(
              get: { model.isCategoryChecked(entry.id) },
              set: { _ in model.toggleCategory(entry.id) })
          ) {
            HStack(spacing: 8) {
              Circle().fill(TxnPalette.tile(entry.option.colorHex)).frame(width: 8, height: 8)
              Text(entry.option.label).fontWeight(entry.option.isChild ? .regular : .medium)
              Spacer(minLength: 8)
              countLabel(entry.count, impossible: entry.isImpossible)
            }
          }
          .toggleStyle(.checkbox)
          .padding(.leading, entry.option.isChild ? 20 : 0)
          .padding(.vertical, 3)
        }
      }
      .font(.system(size: 13))
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 270)
    .frame(maxHeight: 360)
  }

  /// Accounts A–Z under their group names (R-MGMT-8); only those with rows under the other
  /// filters, and, while a debt is selected, only that debt's accounts (C24).
  private var accountsPopover: some View {
    let sections = model.accountSections
    return ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        if sections.isEmpty { emptyNote("No accounts under the other filters.") }
        ForEach(sections) { section in
          if let title = section.title {
            Text(title)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
              .padding(.top, section.id == sections.first?.id ? 0 : 6)
          } else if section.id != sections.first?.id {
            Divider().padding(.vertical, 4)
          }
          ForEach(section.accounts) { account in
            accountToggle(account, indented: section.title != nil)
          }
        }
      }
      .font(.system(size: 13))
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 270)
    .frame(maxHeight: 400)
  }

  private func accountToggle(_ account: Account, indented: Bool) -> some View {
    Toggle(
      isOn: Binding(
        get: { model.filters.accountIDs.contains(account.id) },
        set: { _ in model.filters.toggleAccount(account.id) })
    ) {
      HStack(spacing: 6) {
        Text(account.name).lineLimit(1)
        Spacer(minLength: 8)
        countLabel(model.accountCount(account.id), impossible: model.isAccountImpossible(account.id))
        Text(account.currency.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.checkbox)
    .padding(.leading, indented ? 10 : 0)
    .padding(.vertical, 3)
  }

  /// Debts A–Z with a search field; ticking a debt selects its accounts. Only debts with rows
  /// under the other filters (and the ticked ones) are listed.
  private var debtsPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField("Search debts", text: $debtSearch)
        .textFieldStyle(.roundedBorder)
      let options = model.debtMenu(matching: debtSearch)
      if options.isEmpty {
        emptyNote(
          model.debtOptions.isEmpty ? "No debts yet." : (debtSearch.isEmpty ? "No debts under the other filters." : "No debt matches."))
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(options) { debt in
            Toggle(
              isOn: Binding(get: { model.isDebtChecked(debt.id) }, set: { _ in model.toggleDebt(debt.id) })
            ) {
              HStack {
                Text(debt.name)
                Spacer(minLength: 8)
                if model.isDebtImpossible(debt) {
                  countLabel(nil, impossible: true)
                } else {
                  Text(debt.accountIDs.count == 1 ? "1 account" : "\(debt.accountIDs.count) accounts")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
              }
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, 3)
          }
        }
      }
      .frame(maxHeight: 280)
    }
    .font(.system(size: 13))
    .padding(10)
    .frame(width: 270)
    .task { await model.loadDebtOptions() }
  }

  private var typesPopover: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(model.typeMenu, id: \.type) { entry in
        Toggle(
          isOn: Binding(
            get: { model.filters.types.contains(entry.type) },
            set: { _ in model.filters.toggleType(entry.type) })
        ) {
          HStack {
            Text(entry.title)
            Spacer(minLength: 8)
            countLabel(entry.count, impossible: entry.isImpossible)
          }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 3)
      }
    }
    .font(.system(size: 13))
    .padding(10)
    .frame(width: 200)
  }

  private var eventPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button("Any event") {
        model.filters.eventID = nil
        open = nil
      }
      .buttonStyle(TxnMenuItemStyle(isChosen: model.filters.eventID == nil))
      ForEach(model.eventOptions) { event in
        let impossible = model.filters.eventID == event.id && model.isEventImpossible
        Button {
          model.filters.eventID = event.id
          open = nil
        } label: {
          HStack {
            Text(event.name)
            Spacer(minLength: 8)
            countLabel(model.eventCount(event.id), impossible: impossible)
          }
        }
        .buttonStyle(TxnMenuItemStyle(isChosen: model.filters.eventID == event.id))
      }
    }
    .padding(6)
    .frame(width: 230)
  }
}
