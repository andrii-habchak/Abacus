import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Upcoming section (approved prototype `N5-upcoming`, R-REC-10): toolbar tabs Bills ·
/// Forecast and "New scheduled item"; Bills has the views Upcoming (suggestions, range totals,
/// grouped occurrences with row actions) and All items; the item editor is a sheet (R-REC-12).
struct UpcomingView: View {
  @Bindable var model: UpcomingModel
  var displayCurrency: Currency

  var body: some View {
    content
      .background(UpcomingPalette.page)
      .navigationTitle("Upcoming")
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Picker("Upcoming tabs", selection: $model.tab) {
            ForEach(UpcomingModel.Tab.allCases) { tab in Text(tab.title).tag(tab) }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
          Button("New scheduled item", systemImage: "plus") { model.newItem() }
            .labelStyle(.titleAndIcon)
            .help("A bill, subscription, salary or transfer that repeats")
        }
      }
      .sheet(item: $model.editor) { editor in
        ScheduledItemEditorSheet(editor: editor)
      }
      .sheet(item: $model.linkPicker) { picker in
        UpcomingLinkSheet(model: model, picker: picker)
      }
      .onChange(of: displayCurrency, initial: true) { _, currency in model.displayCurrency = currency }
      .task {
        if model.phase == .idle { await model.load() }
        #if DEBUG
          UpcomingDebugLaunch.apply(to: model)
        #endif
      }
  }

  @ViewBuilder private var content: some View {
    switch model.tab {
    case .forecast:
      UpcomingForecastPlaceholder()
    case .bills:
      switch model.phase {
      case .failed(let message):
        ContentUnavailableView {
          Label("Upcoming", systemImage: "clock")
        } description: {
          Text(message)
        } actions: {
          Button("Try again") { Task { await model.load() } }
        }
      case .idle, .loading:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Picker("View", selection: $model.view) {
              Text("Upcoming").tag(UpcomingModel.View.upcoming)
              Text("All items (\(model.items.count))").tag(UpcomingModel.View.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let notice = model.notice {
              UpcomingNotice(text: notice) { model.notice = nil }
            }
            UpcomingSuggestionsCard(model: model)
            switch model.view {
            case .upcoming: UpcomingBillsList(model: model)
            case .all: UpcomingAllItems(model: model)
            }
          }
          .padding(20)
          .frame(maxWidth: 1180, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
      }
    }
  }
}

/// The Forecast tab until the Forecast lane's view replaces it (N5d builds `ForecastView`).
struct UpcomingForecastPlaceholder: View {
  var body: some View {
    Text("Forecast")
      .font(.title3)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Bills

/// Range card with header totals, then the groups Overdue · Today · This week · Later.
struct UpcomingBillsList: View {
  @Bindable var model: UpcomingModel

  var body: some View {
    let totals = model.totals
    VStack(alignment: .leading, spacing: 4) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Next \(model.rangeDays) days").font(.headline).foregroundStyle(.secondary)
          Spacer()
          Picker("Range", selection: $model.rangeDays) {
            ForEach(UpcomingModel.ranges, id: \.self) { Text("\($0) days").tag($0) }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        HStack(alignment: .bottom, spacing: 28) {
          UpcomingFigure(
            title: "Money out", text: "−" + model.money(totals.outMinor, totals.currency), color: UpcomingPalette.negative)
          UpcomingFigure(
            title: "Money in", text: "+" + model.money(totals.inMinor, totals.currency), color: UpcomingPalette.positive)
          UpcomingFigure(title: "Net", text: model.signedMoney(totals.netMinor, totals.currency), color: .primary)
          Spacer(minLength: 12)
          Text(model.totalsNote)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 360, alignment: .trailing)
        }
      }
      .upcomingCard()
      let groups = model.groups
      if groups.isEmpty {
        Text(model.items.isEmpty ? "No scheduled items yet. Add your bills with “New scheduled item”." : "Nothing scheduled in this range.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(24)
          .upcomingRows()
          .padding(.top, 12)
      }
      ForEach(groups, id: \.group) { group in
        HStack(spacing: 8) {
          Text(group.group.title).fontWeight(.semibold)
            .foregroundStyle(group.group == .overdue ? UpcomingPalette.negative : .secondary)
          Text("\(group.rows.count)").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .padding(.horizontal, 4)
        VStack(spacing: 0) {
          ForEach(group.rows) { row in
            UpcomingBillRow(model: model, row: row)
            if row.id != group.rows.last?.id { Divider().padding(.leading, 56) }
          }
        }
        .upcomingRows()
      }
    }
  }
}

struct UpcomingFigure: View {
  let title: String
  let text: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(text).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
    }
  }
}

/// One occurrence: tile, description + chip, "Category · Monthly", account, day + relative day,
/// amount (+ converted), actions (R-REC-4).
struct UpcomingBillRow: View {
  let model: UpcomingModel
  let row: UpcomingRow

  var body: some View {
    HStack(spacing: 12) {
      UpcomingTile(initial: row.initial, hex: row.colorHex)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.title).lineLimit(1)
          if let chip = row.chip { UpcomingChip(chip) }
        }
        Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
      Text(row.accountText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: 170, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.dayText)
        Text(row.relativeText).font(.caption)
          .foregroundStyle(row.isOverdue ? UpcomingPalette.negative : .secondary)
      }
      .frame(width: 110, alignment: .leading)
      VStack(alignment: .trailing, spacing: 2) {
        Text(row.amountText).fontWeight(.semibold).monospacedDigit()
          .foregroundStyle(row.isIncome ? UpcomingPalette.positive : .primary)
        if let converted = row.convertedText {
          Text(converted).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .frame(width: 130, alignment: .trailing)
      actions.frame(width: 190, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .opacity(row.isResolved ? 0.62 : 1)
    .contentShape(Rectangle())
    .contextMenu { menuItems }
  }

  @ViewBuilder private var actions: some View {
    if let resolved = row.occurrence.resolved {
      HStack(spacing: 6) {
        if let text = row.resolvedText {
          Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
        }
        Button(resolved.status == .paid ? "Unlink" : "Undo") { Task { await model.reopen(row.occurrence) } }
          .controlSize(.small)
          .help(resolved.status == .paid ? "Back to expected; this transaction is not matched again" : "Back to expected")
      }
    } else {
      HStack(spacing: 6) {
        Button("Mark paid") { model.markPaid(row.occurrence) }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .help("Opens a new transaction pre-filled from the item; saving it marks this one paid")
        Menu {
          menuItems
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("More actions for \(row.title)")
      }
    }
  }

  @ViewBuilder private var menuItems: some View {
    if row.isResolved {
      Button(row.occurrence.resolved?.status == .paid ? "Unlink" : "Undo skip") {
        Task { await model.reopen(row.occurrence) }
      }
    } else {
      Button("Mark paid") { model.markPaid(row.occurrence) }
      Button("Link existing transaction…") { Task { await model.beginLink(row.occurrence) } }
      Button("Skip this one") { Task { await model.skip(row.occurrence) } }
    }
    Divider()
    Button("Edit item…") { model.edit(row.occurrence.item.id) }
  }
}

// MARK: - All items

struct UpcomingAllItems: View {
  @Bindable var model: UpcomingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        PageSearchField(text: $model.search, prompt: "Search scheduled items")
          .frame(minWidth: 200, maxWidth: 360)
        Spacer()
        Text("Average per month (display currency, excluding transfers): ")
          .font(.caption).foregroundStyle(.secondary)
          + Text(model.monthlyAverageText).font(.caption.weight(.semibold))
      }
      let rows = model.allRows
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Color.clear.frame(width: 28, height: 1)
          Text("Item").frame(maxWidth: .infinity, alignment: .leading)
          Text("Account").frame(width: 190, alignment: .leading)
          Text("Repeat").frame(width: 150, alignment: .leading)
          Text("Amount").frame(width: 130, alignment: .trailing)
          Color.clear.frame(width: 60, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        Divider()
        if rows.isEmpty {
          Text(model.items.isEmpty ? "No scheduled items yet." : "No item matches the search.")
            .font(.callout).foregroundStyle(.secondary).padding(24)
        }
        ForEach(rows) { row in
          itemRow(row)
          if row.id != rows.last?.id { Divider().padding(.leading, 56) }
        }
      }
      .upcomingRows()
    }
  }

  private func itemRow(_ row: ScheduledItemRow) -> some View {
    HStack(spacing: 12) {
      UpcomingTile(initial: row.initial, hex: row.colorHex)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.title).lineLimit(1)
          if let chip = row.chip { UpcomingTextChip(text: chip, tint: .secondary) }
        }
        Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(row.accountText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        .frame(width: 190, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.repeatText)
        Text(row.nextText).font(.caption).foregroundStyle(.secondary)
      }
      .frame(width: 150, alignment: .leading)
      VStack(alignment: .trailing, spacing: 2) {
        Text(row.amountText).fontWeight(.semibold).monospacedDigit()
          .foregroundStyle(row.isIncome ? UpcomingPalette.positive : .primary)
        if let converted = row.convertedText {
          Text(converted).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .frame(width: 130, alignment: .trailing)
      Button("Edit") { model.edit(row.id) }
        .controlSize(.small)
        .frame(width: 60, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .opacity(row.isDimmed ? 0.6 : 1)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.edit(row.id) }
  }
}

// MARK: - Suggestions (R-REC-8, R-REC-16)

struct UpcomingSuggestionsCard: View {
  @Bindable var model: UpcomingModel

  var body: some View {
    let rows = model.visibleSuggestions
    if !rows.isEmpty || !model.dismissals.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Suggestions (\(rows.count))").font(.headline).foregroundStyle(.secondary)
          Spacer()
          if !model.dismissals.isEmpty {
            Button(model.showsDismissed ? "Hide dismissed" : "Show dismissed (\(model.dismissals.count))") {
              model.showsDismissed.toggle()
            }
            .buttonStyle(.link)
            .controlSize(.small)
          }
          Button(model.suggestionsCollapsed ? "Show" : "Hide") { model.suggestionsCollapsed.toggle() }
            .controlSize(.small)
        }
        if !model.suggestionsCollapsed {
          if !rows.isEmpty {
            Text(
              "Found in your transactions: three or more with the same description, a similar amount and a regular interval. Nothing is created until you accept."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          ForEach(rows) { row in suggestion(row) }
          if model.showsDismissed {
            VStack(alignment: .leading, spacing: 6) {
              Text("Dismissed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              ForEach(model.dismissals) { dismissal in
                HStack {
                  Text(model.dismissalText(dismissal)).font(.callout).lineLimit(1)
                  Spacer()
                  Button("Restore") { Task { await model.restore(dismissal) } }.controlSize(.small)
                }
              }
            }
            .padding(.top, 4)
          }
        }
      }
      .upcomingCard()
    }
  }

  private func suggestion(_ row: SuggestionRow) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        UpcomingTile(initial: row.initial, hex: row.colorHex)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(row.title).font(.body.weight(.medium)).lineLimit(1)
            UpcomingTextChip(text: row.confidenceText, tint: row.isHighConfidence ? UpcomingPalette.positive : .secondary)
          }
          Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(row.amountText).fontWeight(.semibold).monospacedDigit()
        Button("Accept…") { model.accept(row.suggestion) }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        Button("Not now") { model.notNow(row.suggestion) }
          .controlSize(.small)
        Button("Dismiss") { Task { await model.dismiss(row.suggestion) } }
          .controlSize(.small)
          .foregroundStyle(UpcomingPalette.negative)
      }
      HStack(spacing: 6) {
        ForEach(row.evidence, id: \.self) { text in
          Text(text).font(.caption2).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(UpcomingPalette.evidence))
        }
      }
      .accessibilityLabel("Evidence: " + row.evidence.joined(separator: ", "))
    }
    .padding(12)
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UpcomingPalette.border))
  }
}

// MARK: - Link existing (R-REC-4)

struct UpcomingLinkSheet: View {
  let model: UpcomingModel
  let picker: UpcomingLinkPicker
  @Environment(\.dismiss) private var dismiss
  @State private var selection: Txn.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Link an existing transaction").font(.headline)
        Text(picker.title).font(.callout)
        Text(picker.windowText).font(.caption).foregroundStyle(.secondary)
      }
      .padding(20)
      if picker.candidates.isEmpty {
        Text("No transaction in the match window. Add it first, or use Mark paid.")
          .font(.callout).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(picker.candidates, selection: $selection) { candidate in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(candidate.payee).lineLimit(1)
              Text("\(candidate.dayText) · \(candidate.deltaText)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(candidate.amountText).monospacedDigit()
          }
          .tag(candidate.txnID)
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { model.linkPicker = nil }
          .keyboardShortcut(.cancelAction)
        Button("Link") {
          guard let selection else { return }
          Task { await model.link(selection) }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(selection == nil)
      }
      .padding(20)
    }
    .frame(width: 480, height: 400)
  }
}

// MARK: - Pieces

enum UpcomingPalette {
  static let page = Color(nsColor: .windowBackgroundColor)
  static let card = Color(nsColor: .controlBackgroundColor)
  static let border = ManagePalette.border
  static let negative = ManagePalette.negative
  static let positive = ManagePalette.dynamic(light: 0x1B6B3A, dark: 0x7FE0A8)
  static let evidence = ManagePalette.badge
  static let todayText = ManagePalette.dynamic(light: 0x0A4FA8, dark: 0xA9CBFF)
}

extension View {
  func upcomingCard() -> some View {
    padding(.horizontal, 18)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(UpcomingPalette.card, in: .rect(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UpcomingPalette.border))
  }

  func upcomingRows() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .background(UpcomingPalette.card, in: .rect(cornerRadius: 10))
      .clipShape(.rect(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UpcomingPalette.border))
  }
}

/// The category-coloured initial tile.
struct UpcomingTile: View {
  let initial: String
  let hex: String?

  var body: some View {
    Text(initial)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(CategoryColor.color(hex), in: .rect(cornerRadius: 7))
      .accessibilityHidden(true)
  }
}

struct UpcomingChip: View {
  let chip: UpcomingRow.Chip

  init(_ chip: UpcomingRow.Chip) { self.chip = chip }

  var body: some View {
    let tint: Color =
      switch chip {
      case .overdue: UpcomingPalette.negative
      case .today: UpcomingPalette.todayText
      case .paid: UpcomingPalette.positive
      case .skipped: .secondary
      }
    UpcomingTextChip(text: chip.title, tint: tint)
  }
}

struct UpcomingTextChip: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Capsule().fill(tint.opacity(0.13)))
      .fixedSize()
  }
}

struct UpcomingNotice: View {
  let text: String
  let onClose: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Image(systemName: "info.circle").foregroundStyle(.secondary)
      Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
      Button("Close", systemImage: "xmark", action: onClose)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .upcomingCard()
  }
}

#if DEBUG
  /// `-AbacusUpcomingView all` / `-AbacusUpcomingEditor new|first|suggestion` for snapshots.
  enum UpcomingDebugLaunch {
    @MainActor
    static func apply(to model: UpcomingModel) {
      let defaults = UserDefaults.standard
      if defaults.string(forKey: "AbacusUpcomingView") == "all" { model.view = .all }
      if defaults.string(forKey: "AbacusUpcomingTab") == "forecast" { model.tab = .forecast }
      switch defaults.string(forKey: "AbacusUpcomingEditor") {
      case "new": model.newItem()
      case "first": if let item = model.items.first { model.edit(item.id) }
      case "suggestion": if let first = model.suggestions.first { model.accept(first) }
      default: break
      }
    }
  }
#endif

#Preview("Upcoming") {
  let model = UpcomingModel(dependencies: .preview())
  return UpcomingView(model: model, displayCurrency: .PLN)
    .frame(width: 1100, height: 800)
}
