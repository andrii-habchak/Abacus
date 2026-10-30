import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The single-select account picker used everywhere in the app (C37), the account twin of
/// `CategoryPicker`: a button with the current choice that opens a popover with a search field
/// (focused at once), a scrolling list grouped under the account group headings, and keyboard
/// navigation (up/down, return; escape closes). Search rules (name, currency code, group name;
/// case and diacritics ignored; archived accounts hidden unless chosen) live in `AccountSearch`.
///
/// - `items`: the rows in picker order (`AccountPickerItem.items(from:)` over `AccountPickerSection`s).
/// - `selection`: the chosen account; nil = nothing chosen.
/// - `excluding`: accounts that cannot be chosen (e.g. the other side of a transfer).
/// - `noneTitle`: when set, the list starts with a row for nil (also the button text while nothing
///   is chosen), e.g. "No account".
/// - `fixedTitle`: a button that always reads this ("Account" in the import bulk bar) instead of
///   the choice.
struct AccountPicker: View {
  let items: [AccountPickerItem]
  @Binding var selection: Account.ID?
  var excluding: Set<Account.ID> = []
  var noneTitle: String?
  var placeholder = "Choose…"
  var fixedTitle: String?
  /// Fixed width of the button; nil = as wide as its text (`.infinity` for a full-width one).
  var width: CGFloat?
  var accessibilityTitle = "Account"

  init(
    items: [AccountPickerItem], selection: Binding<Account.ID?>, excluding: Set<Account.ID> = [], noneTitle: String? = nil,
    placeholder: String = "Choose…", fixedTitle: String? = nil, width: CGFloat? = nil, accessibilityTitle: String = "Account"
  ) {
    self.items = items
    _selection = selection
    self.excluding = excluding
    self.noneTitle = noneTitle
    self.placeholder = placeholder
    self.fixedTitle = fixedTitle
    self.width = width
    self.accessibilityTitle = accessibilityTitle
  }

  /// Rows from picker sections (`AccountOrder.pickerSections`).
  init(
    sections: [AccountPickerSection], selection: Binding<Account.ID?>, excluding: Set<Account.ID> = [],
    noneTitle: String? = nil, placeholder: String = "Choose…", fixedTitle: String? = nil, width: CGFloat? = nil,
    accessibilityTitle: String = "Account"
  ) {
    self.init(
      items: AccountPickerItem.items(from: sections), selection: selection, excluding: excluding, noneTitle: noneTitle,
      placeholder: placeholder, fixedTitle: fixedTitle, width: width, accessibilityTitle: accessibilityTitle)
  }

  @State private var isOpen = false
  @State private var query = ""
  @State private var highlight = 0
  /// Set by the arrow keys only, so hovering does not scroll the list under the pointer.
  @State private var scrollTarget: Int?
  @FocusState private var searchFocused: Bool

  var body: some View {
    Button {
      query = ""
      isOpen = true
    } label: {
      HStack(spacing: 6) {
        Text(buttonTitle)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(fixedTitle == nil && selection == nil && noneTitle == nil ? .secondary : .primary)
        if width != nil { Spacer(minLength: 0) }
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: width == .infinity ? .infinity : nil, alignment: .leading)
      .frame(width: width == .infinity ? nil : width, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .popover(isPresented: $isOpen, arrowEdge: .bottom) { popover }
    .accessibilityLabel(Text(accessibilityTitle))
    .accessibilityValue(Text(buttonTitle))
  }

  private var buttonTitle: String {
    if let fixedTitle { return fixedTitle }
    if let selection, let item = items.first(where: { $0.id == selection }) { return item.title }
    return noneTitle ?? placeholder
  }

  // MARK: Rows

  private enum Row: Identifiable {
    case heading(String)
    case choice(index: Int, value: Account.ID?, title: String, isIndented: Bool)

    var id: String {
      switch self {
      case .heading(let text): "h:\(text)"
      case .choice(let index, _, _, _): "c:\(index)"
      }
    }
  }

  private var rows: [Row] {
    var rows: [Row] = []
    var index = 0
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if let noneTitle, trimmed.isEmpty {
      rows.append(.choice(index: index, value: nil, title: noneTitle, isIndented: false))
      index += 1
    }
    let groups = AccountSearch.groups(
      items, query: query, isSelected: { $0 == selection }, excluding: excluding)
    // Headings show when any group has one (ungrouped accounts then sit under no heading, last).
    let hasHeadings = groups.contains { $0.heading != nil }
    for group in groups {
      if let heading = group.heading { rows.append(.heading(heading)) }
      for item in group.items {
        rows.append(.choice(index: index, value: item.id, title: item.title, isIndented: hasHeadings && group.heading != nil))
        index += 1
      }
    }
    return rows
  }

  private func choose(_ index: Int, in rows: [Row]) {
    for row in rows {
      if case .choice(let i, let value, _, _) = row, i == index {
        selection = value
        isOpen = false
        return
      }
    }
  }

  private func startHighlight() -> Int {
    if query.trimmingCharacters(in: .whitespaces).isEmpty {
      for row in rows {
        if case .choice(let index, let value, _, _) = row, value == selection, value != nil { return index }
      }
    }
    return 0
  }

  // MARK: Popover

  private var popover: some View {
    let rows = rows
    let count = rows.reduce(0) { c, r in if case .choice = r { c + 1 } else { c } }
    return VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search accounts", text: $query)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .onSubmit { choose(min(highlight, max(count - 1, 0)), in: rows) }
          .onKeyPress(.downArrow) {
            highlight = min(highlight + 1, max(count - 1, 0))
            scrollTarget = highlight
            return .handled
          }
          .onKeyPress(.upArrow) {
            highlight = max(highlight - 1, 0)
            scrollTarget = highlight
            return .handled
          }
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text("Clear search"))
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      Divider()
      if count == 0 {
        Text("No account matches")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 60)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(rows) { row in rowView(row, rows: rows) }
            }
            .padding(.vertical, 4)
          }
          .onChange(of: scrollTarget) { _, new in
            if let new { proxy.scrollTo("c:\(new)") }
          }
          .onAppear { proxy.scrollTo("c:\(highlight)", anchor: .center) }
        }
        .frame(height: min(CGFloat(rows.count) * 24 + 8, 320))
      }
    }
    .frame(width: 280)
    .onAppear {
      highlight = startHighlight()
      searchFocused = true
    }
    .onChange(of: query) { _, _ in
      highlight = query.trimmingCharacters(in: .whitespaces).isEmpty ? startHighlight() : 0
    }
  }

  @ViewBuilder
  private func rowView(_ row: Row, rows: [Row]) -> some View {
    switch row {
    case .heading(let text):
      Text(text.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    case .choice(let index, let value, let title, let isIndented):
      let selected = value == selection
      Button {
        choose(index, in: rows)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .semibold))
            .opacity(selected ? 1 : 0)
            .frame(width: 12)
          Text(title)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.leading, isIndented ? 14 : 8)
        .padding(.trailing, 8)
        .frame(height: 24)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(index == highlight ? Color.accentColor.opacity(0.18) : .clear)
            .padding(.horizontal, 4))
      }
      .buttonStyle(.plain)
      .id("c:\(index)")
      .onHover { inside in if inside { highlight = index } }
    }
  }
}
