import AbacusDomain
import AbacusFeatures
import SwiftUI

/// Date · Categories · Accounts · Type · Event · Import … Clear filters · sort (approved
/// prototype 2, R-LIST-2/3). The import chip appears only while the list shows one import
/// (R-IMP-6) and has its own clear button.
struct TransactionFilterBar: View {
  @Bindable var model: TransactionsViewModel
  @State private var open: Popover?

  enum Popover: Hashable { case date, categories, accounts, event }

  /// The chips wrap onto a second line when the window is too narrow; no label is squeezed
  /// or broken. "Clear filters" and the sort button stay at the trailing edge of the first line.
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      TxnFlowLayout(spacing: 8, lineSpacing: 8) {
        dateChip
        categoriesChip
        accountsChip
        typeToggles
        eventChip
        importChip
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 8) {
        if model.filters.hasActiveFilters {
          Button("Clear filters") { model.clearFilters() }
            .buttonStyle(.plain)
            .foregroundStyle(TxnPalette.link)
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 6)
        }
        sortButton
      }
      .fixedSize()
      .frame(minHeight: 28)
    }
    .padding(.horizontal, TxnMetrics.horizontalPadding)
    .padding(.vertical, 10)
  }

  // MARK: Chips

  private func chip(_ popover: Popover, active: Bool, label: String, systemImage: String? = nil) -> some View {
    Button {
      open = open == popover ? nil : popover
    } label: {
      HStack(spacing: 6) {
        if let systemImage { Image(systemName: systemImage).font(.system(size: 12)) }
        Text(label).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
    }
    .buttonStyle(TxnChipStyle(isActive: active))
    .popover(isPresented: isOpen(popover), arrowEdge: .bottom) { content(for: popover) }
  }

  private func isOpen(_ popover: Popover) -> Binding<Bool> {
    Binding(get: { open == popover }, set: { if !$0, open == popover { open = nil } })
  }

  private var dateChip: some View {
    chip(.date, active: model.filters.isDateFiltered, label: model.dateLabel, systemImage: "calendar")
  }

  private var categoriesChip: some View {
    chip(.categories, active: model.filters.isCategoryFiltered, label: model.categoryLabel)
  }

  private var accountsChip: some View {
    chip(.accounts, active: !model.filters.accountIDs.isEmpty, label: model.accountLabel)
  }

  private var eventChip: some View {
    chip(.event, active: model.filters.eventID != nil, label: model.eventLabel)
  }

  /// "Import: <file> · <date>" with an × that removes only this filter.
  @ViewBuilder
  private var importChip: some View {
    if let label = model.importLabel {
      HStack(spacing: 6) {
        Image(systemName: "square.and.arrow.down").font(.system(size: 12))
        Text(label).lineLimit(1).truncationMode(.middle)
        Button {
          model.clearImportFilter()
        } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .help("Show all transactions, not only this import")
        .accessibilityLabel("Remove import filter")
      }
      .modifier(TxnChipLook(isActive: true))
      .frame(maxWidth: 320)
      .accessibilityElement(children: .contain)
    }
  }

  private var typeToggles: some View {
    HStack(spacing: 2) {
      ForEach([(TxnType.expense, "Expense"), (.income, "Income"), (.transfer, "Transfer")], id: \.0) { type, title in
        let isOn = model.filters.types.contains(type)
        Button(title) { model.filters.toggleType(type) }
          .buttonStyle(TxnSegmentStyle(isOn: isOn))
          .lineLimit(1)
          .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: 7).fill(TxnPalette.segmentTrack))
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Type")
  }

  private var sortButton: some View {
    Button {
      model.filters.newestFirst.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
        Text(model.filters.newestFirst ? "Newest first" : "Oldest first")
      }
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
    case .event: eventPopover
    }
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
    ScrollView {
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
            }
          }
          .toggleStyle(.checkbox)
          .padding(.vertical, 3)
          Divider().padding(.vertical, 4)
        }
        ForEach(model.reference.categories.options) { option in
          Toggle(
            isOn: Binding(
              get: { model.isCategoryChecked(option.id) },
              set: { _ in model.toggleCategory(option.id) })
          ) {
            HStack(spacing: 8) {
              Circle().fill(TxnPalette.tile(option.colorHex)).frame(width: 8, height: 8)
              Text(option.label).fontWeight(option.isChild ? .regular : .medium)
            }
          }
          .toggleStyle(.checkbox)
          .padding(.leading, option.isChild ? 20 : 0)
          .padding(.vertical, 3)
        }
      }
      .font(.system(size: 13))
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 250)
    .frame(maxHeight: 360)
  }

  /// Accounts A–Z under their group names (R-MGMT-8).
  private var accountsPopover: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(model.accountSections) { section in
        if let title = section.title {
          Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, section.id == model.accountSections.first?.id ? 0 : 6)
        } else if section.id != model.accountSections.first?.id {
          Divider().padding(.vertical, 4)
        }
        ForEach(section.accounts) { account in
          accountToggle(account, indented: section.title != nil)
        }
      }
    }
    .font(.system(size: 13))
    .padding(10)
    .frame(width: 240)
  }

  private func accountToggle(_ account: Account, indented: Bool) -> some View {
    Toggle(
      isOn: Binding(
        get: { model.filters.accountIDs.contains(account.id) },
        set: { _ in model.filters.toggleAccount(account.id) })
    ) {
      HStack {
        Text(account.name)
        Spacer()
        Text(account.currency.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.checkbox)
    .padding(.leading, indented ? 10 : 0)
    .padding(.vertical, 3)
  }

  private var eventPopover: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button("Any event") {
        model.filters.eventID = nil
        open = nil
      }
      .buttonStyle(TxnMenuItemStyle(isChosen: model.filters.eventID == nil))
      ForEach(model.eventOptions) { event in
        Button(event.name) {
          model.filters.eventID = event.id
          open = nil
        }
        .buttonStyle(TxnMenuItemStyle(isChosen: model.filters.eventID == event.id))
      }
    }
    .padding(6)
    .frame(width: 200)
  }
}
