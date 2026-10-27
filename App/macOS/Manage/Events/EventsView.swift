import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Events screen (approved prototype group 4, R-MGMT-4, R-EVT-1…4): the page search
/// (R-MGMT-11), events with dates and spent against the budget, the inspector (dates, optional
/// budget, spent by category, "Show N transactions", Archive, Delete…); "New event" in the toolbar.
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
      HStack(spacing: 0) {
        EventsList(model: model)
          .frame(minWidth: 380, maxWidth: .infinity)
        Divider()
        EventInspectorView(model: model, onShowTransactions: onShowTransactions)
      }
    }
    .navigationTitle("Events")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("New event", systemImage: "plus") { model.newEvent() }
          .labelStyle(.titleAndIcon)
      }
    }
    .sheet(item: Binding(get: { model.dialog }, set: { if $0 == nil { model.cancelDialog() } })) { dialog in
      ManageDialogView(dialog: dialog, onCancel: model.cancelDialog) {
        Task { await model.confirmDialog() }
      }
    }
    .onChange(of: displayCurrency, initial: true) { _, currency in model.setDisplayCurrency(currency) }
    .task {
      if model.phase == .idle { await model.load() }
      #if DEBUG
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
          EventRowView(row: row).tag(row.id)
        }
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
    }
    .font(.system(size: 13))
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }
}

/// Name, Starts / Ends (each optional), budget with what was spent right under it, colour,
/// "Show N transactions"; then Archive / Unarchive and Delete… in their own row, and Revert /
/// Save changes at the bottom-right (R-EVT-1…3, R-MGMT-4, R-MGMT-10). An archived event's name,
/// dates, budget and currency are read-only until it is unarchived; its colour stays editable.
struct EventInspectorView: View {
  let model: EventsModel
  let onShowTransactions: (Event.ID) -> Void

  private func binding<Value>(_ keyPath: WritableKeyPath<EventDraft, Value>, _ fallback: Value) -> Binding<Value> {
    draftBinding({ model.draft }, { model.draft = $0 }, keyPath, fallback: fallback)
  }

  var body: some View {
    if let draft = model.draft {
      let readOnly = model.isReadOnly
      ManageInspector(title: model.inspectorTitle) {
        if readOnly {
          Label("Archived. Unarchive it to change the name, dates or budget.", systemImage: "archivebox")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        ManageField("Name") {
          TextField("Name", text: binding(\.name, ""), prompt: Text("e.g. Lyon trip"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .disabled(readOnly)
        }
        HStack(alignment: .top, spacing: 8) {
          dateField("Starts", isOn: binding(\.hasStart, false), date: binding(\.start, Date()), readOnly: readOnly)
          dateField("Ends", isOn: binding(\.hasEnd, false), date: binding(\.end, Date()), readOnly: readOnly)
        }
        ManageField("Budget (optional)") {
          HStack(spacing: 6) {
            TextField("Budget", text: binding(\.budget, ""), prompt: Text("No budget"))
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .monospacedDigit()
            Picker("Budget currency", selection: binding(\.budgetCurrency, .EUR)) {
              ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
          }
          .disabled(readOnly)
        }
        if !draft.isNew { spentCard }
        ManageField("Colour") {
          ManageColorField(hex: binding(\.colorHex, nil))
        }
        if !readOnly {
          Text("While the event's dates are active, new expenses are tagged with it by default.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !draft.isNew {
          Button(model.showTransactionsTitle) {
            if let id = model.selection { onShowTransactions(id) }
          }
          .buttonStyle(.link)
          .foregroundStyle(ManagePalette.link)
          Divider().padding(.vertical, 2)
          HStack(spacing: 8) {
            Button(model.archiveTitle) { Task { await model.archiveOrUnarchive() } }
            Button("Delete…", role: .destructive) { model.requestDelete() }
              .foregroundStyle(ManagePalette.destructive)
            Spacer(minLength: 0)
          }
          .controlSize(.small)
        }
        ManageSaveBar(
          isNew: draft.isNew, isDirty: model.isDirty, canSave: model.canSave, validation: model.validationMessage,
          error: model.errorMessage, onRevert: model.revert
        ) {
          Task { await model.save() }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    } else {
      ManageInspector(title: "") {
        Text("Select an event or create one.").foregroundStyle(.secondary)
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
  /// page search, `-AbacusEventsEditBudget <text>` types into the budget field (Save bar).
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
      if let budget = defaults.string(forKey: "AbacusEventsEditBudget") { model.draft?.budget = budget }
      DebugWindowSize.applyIfRequested()
    }
  }
#endif

#Preview("Events") {
  EventsView(dependencies: .preview(), displayCurrency: .PLN)
    .frame(width: 1000, height: 700)
}
