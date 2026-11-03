import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Events screen (approved prototype group 4, R-MGMT-4, R-EVT-1…4): the page search
/// (R-MGMT-11), events with dates and spent against the budget; the editor (dates, optional
/// budget, spent by category, "Show N transactions", Archive, Delete…) is a sheet opened by
/// double-click / Return / "Edit…"; Archive and Delete icons on each row; "New event" in the toolbar.
///
/// `onShowTransactions` opens Transactions filtered by the event (the shell routes it, e.g.
/// `TransactionFilters.event(_:)`).
public struct EventsView: View {
  @State private var model: EventsModel
  var displayCurrency: Currency
  var onShowTransactions: (Event.ID) -> Void

  public init(model: EventsModel, displayCurrency: Currency = .UAH, onShowTransactions: @escaping (Event.ID) -> Void = { _ in }) {
    _model = State(initialValue: model)
    self.displayCurrency = displayCurrency
    self.onShowTransactions = onShowTransactions
  }

  public init(
    dependencies: ManageDependencies, displayCurrency: Currency = .UAH,
    onShowTransactions: @escaping (Event.ID) -> Void = { _ in }
  ) {
    self.init(
      model: EventsModel(dependencies: dependencies, displayCurrency: displayCurrency), displayCurrency: displayCurrency,
      onShowTransactions: onShowTransactions)
  }

  public var body: some View {
    ManagePhaseView(phase: model.phase, title: "Events", retry: { await model.load() }) {
      EventsList(model: model)
        .frame(minWidth: 380, maxWidth: .infinity)
    }
    .navigationTitle("Events")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("New event", systemImage: "plus") { model.newEvent() }
          .labelStyle(.titleAndIcon)
      }
    }
    .sheet(item: Binding(get: { model.sheet }, set: { if $0 == nil, model.sheet != nil { model.dismissSheet() } })) {
      draft in
      EventEditorSheet(model: model, initial: draft, onShowTransactions: onShowTransactions)
    }
    // Confirmations raised from the list; the editor sheet shows its own.
    .sheet(
      item: Binding(
        get: { model.sheet == nil ? model.dialog : nil },
        set: { if $0 == nil, model.sheet == nil, model.dialog != nil { model.cancelDialog() } })
    ) { dialog in
      ManageDialogView(dialog: dialog, onCancel: model.cancelDialog) {
        Task { await model.confirmDialog() }
      }
    }
    .onChange(of: displayCurrency, initial: true) { _, currency in model.setDisplayCurrency(currency) }
    .task {
      if model.phase == .idle { await model.load() }
      #if DEBUG
        for _ in 0..<50 where model.phase != .loaded || model.rows.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        EventsDebugLaunch.apply(to: model)
      #endif
    }
  }
}

struct EventsList: View {
  @Bindable var model: EventsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageSearchField(text: $model.search, prompt: "Search events")
        .padding(.horizontal, ManageMetrics.horizontalPadding)
        .padding(.top, 12)
      Toggle("Show archived events", isOn: Binding(get: { model.showArchived }, set: { model.setShowArchived($0) }))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .padding(.horizontal, ManageMetrics.horizontalPadding)
        .padding(.vertical, 8)
      List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
        ForEach(model.rows) { row in
          EventRowView(
            row: row,
            onArchive: { Task { await model.archiveOrUnarchive(row.id) } },
            onDelete: { model.requestDelete(row.id) }
          )
          .tag(row.id)
        }
      }
      .contextMenu(forSelectionType: Event.ID.self) { ids in
        if let id = ids.first {
          Button("Edit…") { model.edit(id) }
          Button(model.archiveTitle(for: id)) { Task { await model.archiveOrUnarchive(id) } }
          Button("Delete…", role: .destructive) { model.requestDelete(id) }
        }
      } primaryAction: { ids in
        if let id = ids.first { model.edit(id) }
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
      .overlay {
        if model.rows.isEmpty {
          Text(emptyMessage)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        }
      }
    }
  }

  private var emptyMessage: String {
    let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      ? "No events yet. Create one for a trip, a move or the car."
      : "No events match “\(query)”."
  }
}

/// Name and dates; spent with "of X budget" / "no budget".
struct EventRowView: View {
  let row: EventRow
  let onArchive: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      ManageDot(hex: row.colorHex)
        .opacity(row.isArchived ? 0.45 : 1)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.name).fontWeight(.medium)
          if row.isArchived {
            Text("Archived")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(ManagePalette.badge, in: .capsule)
          }
        }
        Text(row.dates).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(row.spentText)
          .fontWeight(.semibold)
          .monospacedDigit()
          .foregroundStyle(row.status == .over ? ManagePalette.negative : Color.primary)
        Text(row.budgetText).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      HStack(spacing: 2) {
        EventRowIconButton(
          systemImage: row.isArchived ? "tray.and.arrow.up" : "archivebox", help: row.isArchived ? "Unarchive" : "Archive",
          tint: .accentColor, action: onArchive)
        EventRowIconButton(systemImage: "trash", help: "Delete…", tint: ManagePalette.destructive, action: onDelete)
      }
    }
    .font(.system(size: 13))
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
  }
}

/// A subtle icon at the end of an event row; it gets a tinted background while the pointer is
/// over it. A plain button, so a click on it never selects or opens the row.
struct EventRowIconButton: View {
  let systemImage: String
  let help: String
  let tint: Color
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13))
        .foregroundStyle(hovering ? tint : Color.secondary)
        .frame(width: 26, height: 24)
        .background(hovering ? tint.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(help)
  }
}

/// The event editor (like the account and category editors, D55): name, Starts / Ends (each
/// optional), budget with what was spent right under it, colour, "Show N transactions"; Archive /
/// Unarchive and Delete… on the left, Cancel and Save / Create on the right (R-EVT-1…3,
/// R-MGMT-4, R-MGMT-10). An archived event's name, dates, budget and currency are read-only until
/// it is unarchived; its colour stays editable. The form is this sheet's own state; the model
/// sees it on Save.
struct EventEditorSheet: View {
  let model: EventsModel
  let onShowTransactions: (Event.ID) -> Void
  @State private var draft: EventDraft
  /// The form as opened: the validation message waits for the first edit.
  private let initial: EventDraft

  init(model: EventsModel, initial: EventDraft, onShowTransactions: @escaping (Event.ID) -> Void) {
    self.model = model
    self.initial = initial
    self.onShowTransactions = onShowTransactions
    _draft = State(initialValue: initial)
  }

  private var title: String {
    if draft.isNew { return draft.name.isEmpty ? "New event" : draft.name }
    return model.event(draft.id)?.name ?? draft.name
  }

  var body: some View {
    let readOnly = model.isReadOnly(draft)
    ManageEditorSheet(
      title: title,
      message: draft != initial ? model.validationMessage(draft) : nil,
      error: model.errorMessage,
      saveTitle: draft.isNew ? "Create" : "Save",
      canSave: model.canSave(draft),
      onCancel: model.dismissSheet,
      onSave: { Task { await model.save(draft) } }
    ) {
      if readOnly {
        Label("Archived. Unarchive it to change the name, dates or budget.", systemImage: "archivebox")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ManageField("Name") {
        TextField("Name", text: $draft.name, prompt: Text("e.g. Lyon trip"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .disabled(readOnly)
      }
      HStack(alignment: .top, spacing: 8) {
        dateField("Starts", isOn: $draft.hasStart, date: $draft.start, readOnly: readOnly)
        dateField("Ends", isOn: $draft.hasEnd, date: $draft.end, readOnly: readOnly)
      }
      ManageField("Budget (optional)") {
        HStack(spacing: 6) {
          TextField("Budget", text: $draft.budget, prompt: Text("No budget"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
          Picker("Budget currency", selection: $draft.budgetCurrency) {
            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
        .disabled(readOnly)
      }
      if !draft.isNew { spentCard }
      ManageField("Colour") {
        ManageColorField(hex: $draft.colorHex)
      }
      if !readOnly {
        Text("While the event's dates are active, new expenses are tagged with it by default.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !draft.isNew {
        Button(model.showTransactionsTitle) {
          model.dismissSheet()
          onShowTransactions(draft.id)
        }
        .buttonStyle(.link)
        .foregroundStyle(ManagePalette.link)
      }
    } actions: {
      if !draft.isNew, model.event(draft.id) != nil {
        Button(model.archiveTitle(for: draft.id)) { Task { await model.archiveOrUnarchive(draft.id) } }
        Button("Delete…", role: .destructive) { model.requestDelete(draft.id) }
      }
    }
    .sheet(
      item: Binding(get: { model.dialog }, set: { if $0 == nil, model.dialog != nil { model.cancelDialog() } })
    ) { dialog in
      ManageDialogView(dialog: dialog, onCancel: model.cancelDialog) {
        Task { await model.confirmDialog() }
      }
    }
  }

  /// "Spent x of y" and the spending by category (R-EVT-3), right under the budget.
  private var spentCard: some View {
    ManageCard {
      HStack {
        Text("Spent").foregroundStyle(.secondary)
        Spacer()
        Text(model.spentText)
          .fontWeight(.semibold)
          .monospacedDigit()
          .foregroundStyle(model.selectedTotals?.budgetStatus == .over ? ManagePalette.negative : Color.primary)
      }
      ForEach(model.categoryBars) { bar in
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(bar.name)
            Spacer()
            Text(bar.amountText).foregroundStyle(.secondary).monospacedDigit()
          }
          .font(.system(size: 12))
          ManageBar(fraction: bar.fraction, color: ManagePalette.hex(bar.colorHex))
        }
      }
      if let missing = model.missingRatesNote {
        Text(missing).font(.system(size: 11)).foregroundStyle(.orange)
      }
    }
  }

  private func dateField(_ label: String, isOn: Binding<Bool>, date: Binding<Date>, readOnly: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(label, isOn: isOn)
        .toggleStyle(.checkbox)
        .foregroundStyle(.secondary)
        .disabled(readOnly)
      DatePicker(label, selection: date, displayedComponents: .date)
        .labelsHidden()
        .datePickerStyle(.field)
        .disabled(readOnly || !isOn.wrappedValue)
        .opacity(isOn.wrappedValue ? 1 : 0.5)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#if DEBUG
  /// Debug builds only, for UI checks on a scratch database: `-AbacusEventsSelect <name>`
  /// selects that event (showing archived ones if needed), `-AbacusEventsSearch <text>` fills the
  /// page search, `-AbacusOpenSheet newEvent|editEvent` opens the editor sheet (`editEvent` on the
  /// event named by `-AbacusEventsSelect`, else the first row).
  @MainActor
  enum EventsDebugLaunch {
    private static var applied = false

    static func apply(to model: EventsModel) {
      guard !applied else { return }
      applied = true
      let defaults = UserDefaults.standard
      if let name = defaults.string(forKey: "AbacusEventsSelect"),
        let event = model.events.first(where: { $0.name == name })
      {
        if event.isArchived { model.setShowArchived(true) }
        model.select(event.id)
      }
      if let search = defaults.string(forKey: "AbacusEventsSearch") { model.search = search }
      switch defaults.string(forKey: "AbacusOpenSheet") {
      case "newEvent": model.newEvent()
      case "editEvent": if let id = model.selection ?? model.rows.first?.id { model.edit(id) }
      default: break
      }
      DebugWindowSize.applyIfRequested()
    }
  }
#endif

#Preview("Events") {
  EventsView(dependencies: .preview(), displayCurrency: .PLN)
    .frame(width: 1000, height: 700)
}
