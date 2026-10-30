import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Accounts page's filter row (R-MGMT-9, C29): the currency and the account-type dropdown
/// buttons (the look of the Transactions filter chips: bordered, blue outline while a filter is
/// on), "Clear filters" while any is on, and the sort menu at the trailing edge. One row.
struct AccountFilterBar: View {
  let model: AccountsModel
  @State private var showingKinds = false

  var body: some View {
    HStack(spacing: 8) {
      currencyMenu
      kindsButton
      if model.hasActiveFilters {
        Button("Clear filters") { model.clearFilters() }
          .buttonStyle(.plain)
          .foregroundStyle(ManagePalette.link)
          .font(.system(size: 13))
          .lineLimit(1)
          .padding(.horizontal, 4)
      }
      Spacer(minLength: 4)
      Picker("Sort", selection: Binding(get: { model.sort }, set: { sort in Task { await model.setSort(sort) } })) {
        ForEach(AccountSort.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.menu)
      .fixedSize()
      .help("Order of the list")
    }
  }

  private var currencyMenu: some View {
    Menu {
      Picker("Currency", selection: Binding(get: { model.currencyFilter }, set: { model.currencyFilter = $0 })) {
        Text("All currencies").tag(Currency?.none)
        ForEach(model.currencyOptions, id: \.self) { Text($0.rawValue).tag(Currency?.some($0)) }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      HStack(spacing: 6) {
        Text(model.currencyFilter?.rawValue ?? "All currencies").lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .modifier(AccountChipLook(isActive: model.currencyFilter != nil))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Show accounts in one currency")
    .accessibilityLabel("Currency filter")
  }

  private var kindsButton: some View {
    Button {
      showingKinds.toggle()
    } label: {
      HStack(spacing: 6) {
        Text(model.kindFilterLabel).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .modifier(AccountChipLook(isActive: !model.kindFilter.isEmpty))
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help("Show accounts of some types only")
    .accessibilityLabel("Account type filter")
    .popover(isPresented: $showingKinds, arrowEdge: .bottom) { kindList }
  }

  /// A checkbox per kind that exists under the current currency filter.
  private var kindList: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(model.kindOptions, id: \.self) { kind in
        Toggle(
          ManageText.kindTitle(kind),
          isOn: Binding(get: { model.kindFilter.contains(kind) }, set: { _ in model.toggleKind(kind) })
        )
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
      }
      if model.kindOptions.isEmpty {
        Text("No accounts").foregroundStyle(.secondary)
      }
    }
    .font(.system(size: 13))
    .padding(12)
    .frame(minWidth: 190, alignment: .leading)
  }
}

/// The filter button look: bordered; blue outline and tint while its filter is on.
private struct AccountChipLook: ViewModifier {
  var isActive: Bool

  func body(content: Content) -> some View {
    content
      .font(.system(size: 13))
      .foregroundStyle(isActive ? Chip.activeText : Color.primary)
      .padding(.horizontal, 10)
      .frame(minHeight: 28)
      .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Chip.activeBackground : Chip.background))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isActive ? Chip.activeBorder : Chip.border))
      .contentShape(Rectangle())
  }

  private enum Chip {
    static let border = ManagePalette.dynamic(light: 0xD2D2D7, dark: 0x4A4A4D)
    static let background = ManagePalette.dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let activeBorder = ManagePalette.dynamic(light: 0x0A66D9, dark: 0x3D8BFF)
    static let activeBackground = ManagePalette.dynamic(light: 0xEAF2FD, dark: 0x13325C)
    static let activeText = ManagePalette.dynamic(light: 0x0A4FA8, dark: 0xA9CBFF)
  }
}
