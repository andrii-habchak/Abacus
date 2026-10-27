import AbacusDomain
import AbacusFeatures
import SwiftUI
import UniformTypeIdentifiers

/// The Accounts screen (approved prototype group 4, R-MGMT-1, R-MGMT-9, R-ACC-1…5, D48): page
/// search, sort and currency filter, groups as folders with the sum of their accounts, drag and
/// drop like Reminders (between rows reorders, onto a group moves into it), the inspector on the
/// right; "New account" in the toolbar, "New group" next to the sort selector.
///
/// The shell routes `AppSection.accounts` here, keeping the model alive (`init(model:)`) or
/// letting the view own one (`init(dependencies:)`).
public struct AccountsView: View {
  @State private var model: AccountsModel
  /// The currency a new account starts with and group sums are shown in (the display currency).
  var displayCurrency: Currency

  public init(model: AccountsModel, displayCurrency: Currency = .UAH) {
    _model = State(initialValue: model)
    self.displayCurrency = displayCurrency
  }

  public init(dependencies: ManageDependencies, displayCurrency: Currency = .UAH) {
    self.init(model: AccountsModel(dependencies: dependencies), displayCurrency: displayCurrency)
  }

  public var body: some View {
    ManagePhaseView(phase: model.phase, title: "Accounts", retry: { await model.load() }) {
      HStack(spacing: 0) {
        AccountsList(model: model)
          .frame(minWidth: 380, maxWidth: .infinity)
        Divider()
        AccountInspectorView(model: model)
      }
    }
    .navigationTitle("Accounts")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("New account", systemImage: "plus") { model.newAccount(currency: displayCurrency) }
          .labelStyle(.titleAndIcon)
          .help("New account")
      }
    }
    .sheet(item: Binding(get: { model.dialog }, set: { if $0 == nil { model.cancelDialog() } })) { dialog in
      ManageDialogView(dialog: dialog, onCancel: model.cancelDialog) {
        Task { await model.confirmDialog() }
      }
    }
    .onChange(of: displayCurrency, initial: true) { _, currency in model.setDisplayCurrency(currency) }
    .task { if model.phase == .idle { await model.load() } }
  }
}

/// Where a drag would land, for the drop indicator.
struct AccountDropTarget: Equatable {
  /// nil: the space below the last row (top level, last).
  var id: UUID?
  var position: AccountDropPosition
}

/// Search, sort, currency filter, "Show archived accounts" and the grouped list with drag and
/// drop (R-MGMT-1, R-MGMT-9, R-MGMT-11).
struct AccountsList: View {
  let model: AccountsModel
  @State private var dragging: UUID?
  @State private var dropTarget: AccountDropTarget?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageSearchField(text: Binding(get: { model.searchText }, set: { model.searchText = $0 }), prompt: "Search accounts")
        .padding(.horizontal, ManageMetrics.horizontalPadding)
        .padding(.top, 12)
      HStack(spacing: 8) {
        Picker("Currency", selection: Binding(get: { model.currencyFilter }, set: { model.currencyFilter = $0 })) {
          Text("All currencies").tag(Currency?.none)
          ForEach(model.currencyOptions, id: \.self) { Text($0.rawValue).tag(Currency?.some($0)) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Show accounts in one currency")
        Spacer(minLength: 4)
        Picker("Sort", selection: Binding(get: { model.sort }, set: { sort in Task { await model.setSort(sort) } })) {
          ForEach(AccountSort.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Order of the list")
        Button("New group", systemImage: "folder.badge.plus") { model.newGroup() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("New account group")
      }
      .padding(.horizontal, ManageMetrics.horizontalPadding)
      .padding(.top, 10)
      Toggle(
        "Show archived accounts",
        isOn: Binding(get: { model.showArchived }, set: { model.setShowArchived($0) })
      )
      .toggleStyle(.checkbox)
      .font(.system(size: 12))
      .padding(.horizontal, ManageMetrics.horizontalPadding)
      .padding(.top, 8)
      .padding(.bottom, 4)
      List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
        ForEach(model.rows) { row in
          AccountRowView(row: row, indicator: dropTarget?.id == row.id ? dropTarget?.position : nil)
            .tag(row.id)
            .onDrag {
              dragging = row.id
              return NSItemProvider(object: row.id.uuidString as NSString)
            }
            .onDrop(
              of: [.text],
              delegate: AccountDropDelegate(model: model, target: row.id, dragging: $dragging, dropTarget: $dropTarget))
        }
        // Below the last row: top level, last.
        Color.clear
          .frame(height: 44)
          .overlay(alignment: .top) {
            if dropTarget == AccountDropTarget(id: nil, position: .after) {
              Rectangle().fill(Color.accentColor).frame(height: 2)
            }
          }
          .listRowSeparator(.hidden)
          .onDrop(
            of: [.text],
            delegate: AccountDropDelegate(model: model, target: nil, dragging: $dragging, dropTarget: $dropTarget))
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
      .overlay {
        if let message = model.emptySearchMessage {
          Text(message).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// The top or bottom quarter of a row reorders, the middle moves an account into a group
/// (R-MGMT-9, like Reminders).
struct AccountDropDelegate: DropDelegate {
  let model: AccountsModel
  let target: UUID?
  @Binding var dragging: UUID?
  @Binding var dropTarget: AccountDropTarget?

  /// Row height used to split it into before / onto / after.
  static let rowHeight: CGFloat = 44

  private func position(_ info: DropInfo) -> AccountDropPosition {
    guard target != nil else { return .after }
    let y = info.location.y
    if y < Self.rowHeight * 0.28 { return .before }
    if y > Self.rowHeight * 0.72 { return .after }
    return .onto
  }

  private func allowed(_ info: DropInfo) -> AccountDropPosition? {
    guard let dragging else { return nil }
    let position = position(info)
    if model.canDrop(dragging, on: target, position: position) { return position }
    // Not into a group (a group, or onto a top-level account): fall back to a reorder.
    if position == .onto {
      let fallback: AccountDropPosition = info.location.y < Self.rowHeight / 2 ? .before : .after
      if model.canDrop(dragging, on: target, position: fallback) { return fallback }
    }
    return nil
  }

  func validateDrop(info: DropInfo) -> Bool { dragging != nil }

  func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    guard let position = allowed(info) else {
      if dropTarget?.id == target { dropTarget = nil }
      return DropProposal(operation: .forbidden)
    }
    let next = AccountDropTarget(id: target, position: position)
    if dropTarget != next { dropTarget = next }
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    if dropTarget?.id == target { dropTarget = nil }
  }

  func performDrop(info: DropInfo) -> Bool {
    defer {
      dropTarget = nil
      dragging = nil
    }
    guard let moving = dragging, let position = allowed(info) else { return false }
    Task { await model.drop(moving, on: target, position: position) }
    return true
  }
}

/// A group (folder tile, name, "3 accounts", the sum in the display currency) or an account
/// (tile with the currency symbol, name, "Kind · CUR", balance; indented inside a group); the
/// drop indicator (a line above / below, or the group outlined for "move into").
struct AccountRowView: View {
  let row: AccountRow
  var indicator: AccountDropPosition? = nil

  var body: some View {
    HStack(spacing: 12) {
      ManageGrip()
      tile
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.name).fontWeight(row.isGroup ? .semibold : .medium)
          if row.isArchived {
            Text("Archived")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(ManagePalette.badge, in: .capsule)
          }
        }
        Text(row.detail).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(row.balanceText)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(row.isNegative ? ManagePalette.negative : Color.primary)
    }
    .padding(.leading, row.isChild ? 22 : 0)
    .opacity(row.matchesSearch ? 1 : 0.55)
    .font(.system(size: 13))
    .padding(.vertical, 5)
    .contentShape(.rect)
    .overlay(alignment: indicator == .before ? .top : .bottom) {
      if indicator == .before || indicator == .after {
        Rectangle().fill(Color.accentColor).frame(height: 2)
          .padding(.leading, row.isChild ? 50 : 28)
      }
    }
    .overlay {
      if indicator == .onto {
        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var tile: some View {
    if row.isGroup {
      Image(systemName: "folder.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(groupColor, in: .rect(cornerRadius: 8))
        .accessibilityHidden(true)
    } else {
      Text(row.symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(tileColor, in: .rect(cornerRadius: 8))
        .opacity(row.isArchived ? 0.45 : 1)
        .accessibilityHidden(true)
    }
  }

  /// The group's colour, or grey.
  private var groupColor: Color {
    ColorPalette.rgb(row.colorHex) != nil ? ManagePalette.hex(row.colorHex) : Color.secondary
  }

  /// The account's colour (R-MGMT-7); without one, blue for assets and red for liabilities.
  private var tileColor: Color {
    if ColorPalette.rgb(row.colorHex) != nil { return ManagePalette.hex(row.colorHex) }
    return row.isLiability ? ManagePalette.liability : ManagePalette.asset
  }
}

/// The account form or the group form, with Save at the bottom-right (R-MGMT-10).
struct AccountInspectorView: View {
  let model: AccountsModel

  var body: some View {
    if model.groupDraft != nil {
      inspector(isNew: model.groupDraft?.isNew == true) { AccountGroupFields(model: model) }
    } else if model.draft != nil {
      inspector(isNew: model.draft?.isNew == true) { AccountFields(model: model) }
    } else {
      ManageInspector(title: "") {
        Text("Select an account or create one.").foregroundStyle(.secondary)
      }
    }
  }

  private func inspector<Fields: View>(isNew: Bool, @ViewBuilder fields: () -> Fields) -> some View {
    VStack(spacing: 0) {
      ManageInspector(title: model.inspectorTitle) { fields() }
      AccountSaveFooter(model: model, isNew: isNew)
    }
    .frame(width: ManageMetrics.inspectorWidth)
    .background(ManagePalette.inspectorBackground)
  }
}

/// Name, kind, currency (fixed after the first transaction), opening balance and date, group,
/// colour, IBAN, current balance; Archive… / Unarchive and Delete… (R-ACC-1, R-ACC-4, R-ACC-5).
struct AccountFields: View {
  let model: AccountsModel

  private func binding<Value>(_ keyPath: WritableKeyPath<AccountDraft, Value>, _ fallback: Value) -> Binding<Value> {
    draftBinding({ model.draft }, { model.draft = $0 }, keyPath, fallback: fallback)
  }

  var body: some View {
    if let draft = model.draft {
      ManageField("Name") {
        TextField("Name", text: binding(\.name, ""), prompt: Text("e.g. PKO Personal"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
      ManageField("Kind") {
        Picker("Kind", selection: binding(\.kind, .bank)) {
          Section("Assets") {
            ForEach(ManageText.assetKinds, id: \.self) { Text(ManageText.kindTitle($0)).tag($0) }
          }
          Section("Liabilities") {
            ForEach(ManageText.liabilityKinds(offeredFor: binding(\.kind, .bank).wrappedValue), id: \.self) { Text(ManageText.kindTitle($0)).tag($0) }
          }
        }
        .labelsHidden()
      }
      ManageField("Currency") {
        if model.isCurrencyLocked {
          HStack(spacing: 4) {
            Text(draft.currency.rawValue)
            Text("· fixed after the first transaction").font(.system(size: 11)).foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        } else {
          HStack(spacing: 8) {
            Picker("Currency", selection: binding(\.currency, .UAH)) {
              ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Text("fixed after the first transaction").font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
      }
      HStack(alignment: .top, spacing: 8) {
        ManageField("Opening balance") {
          TextField("Opening balance", text: binding(\.openingBalance, ""))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
        }
        ManageField("Opening date") {
          DatePicker("Opening date", selection: binding(\.openingDate, Date()), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.field)
        }
      }
      ManageField("Group") {
        Picker("Group", selection: binding(\.groupID, nil)) {
          Text("None (top level)").tag(AccountGroup.ID?.none)
          ForEach(model.groupOptions) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
      }
      ManageField("Colour") {
        ManageColorField(hex: binding(\.colorHex, nil))
      }
      ManageField("Bank account number (IBAN)") {
        TextField("IBAN", text: binding(\.iban, ""), prompt: Text("Used to recognise transfers in bank imports"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
      if let balance = model.balanceText {
        ManageCard {
          HStack {
            Text("Current balance").foregroundStyle(.secondary)
            Spacer()
            Text(balance)
              .fontWeight(.semibold)
              .monospacedDigit()
              .foregroundStyle(model.isBalanceNegative ? ManagePalette.negative : Color.primary)
          }
        }
      }
      if !draft.isNew {
        HStack(spacing: 8) {
          Button(model.archiveTitle) { Task { await model.archiveOrUnarchive() } }
          Button("Delete…", role: .destructive) { model.requestDelete() }
            .foregroundStyle(model.canDelete ? ManagePalette.destructive : Color.secondary)
            .disabled(!model.canDelete)
            .help(model.deleteHint)
        }
        .padding(.top, 4)
        Text(model.deleteHint).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }
}

/// A group (R-MGMT-9): name, optional colour, its accounts and their sum; Delete… moves its
/// accounts to the top level.
struct AccountGroupFields: View {
  let model: AccountsModel

  private func binding<Value>(_ keyPath: WritableKeyPath<AccountGroupDraft, Value>, _ fallback: Value) -> Binding<Value> {
    draftBinding({ model.groupDraft }, { model.groupDraft = $0 }, keyPath, fallback: fallback)
  }

  var body: some View {
    if let draft = model.groupDraft {
      ManageField("Name") {
        TextField("Name", text: binding(\.name, ""), prompt: Text("e.g. Monobank, PKO"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
      ManageField("Colour") {
        ManageColorField(hex: binding(\.colorHex, nil))
      }
      if let summary = model.selectedGroupSummary, let sum = model.selectedGroupSumText {
        ManageCard {
          HStack {
            Text(summary).foregroundStyle(.secondary)
            Spacer()
            Text(sum).fontWeight(.semibold).monospacedDigit()
          }
          Text("A group holds no money of its own: this is the sum of its accounts in \(model.displayCurrency.rawValue).")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if draft.isNew {
        Text("Drag accounts onto the group to move them in, or pick the group in an account's form.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Button("Delete group…", role: .destructive) { model.requestDeleteGroup() }
          .foregroundStyle(ManagePalette.destructive)
          .padding(.top, 4)
        Text("Its accounts move to the top level.").font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }
}

/// Messages on the left, Revert / Cancel and the primary Save on the right, pinned to the
/// bottom of the inspector (R-MGMT-10).
struct AccountSaveFooter: View {
  let model: AccountsModel
  let isNew: Bool

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if model.isDirty, let validation = model.validationMessage {
        Text(validation).font(.caption).foregroundStyle(ManagePalette.negative)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let error = model.errorMessage {
        Text(error).font(.caption).foregroundStyle(ManagePalette.negative)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 8) {
        Spacer()
        Button(isNew ? "Cancel" : "Revert", action: model.revert)
          .disabled(!model.isDirty)
        Button(isNew ? "Create" : "Save") { Task { await model.save() } }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canSave)
          .keyboardShortcut("s", modifiers: .command)
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .overlay(alignment: .top) { Divider() }
  }
}

#Preview("Accounts") {
  AccountsView(dependencies: .preview())
    .frame(width: 1000, height: 720)
}

#Preview("Accounts · archived shown") {
  let model = AccountsModel(dependencies: .preview())
  model.showArchived = true
  return AccountsView(model: model)
    .frame(width: 1000, height: 720)
}
