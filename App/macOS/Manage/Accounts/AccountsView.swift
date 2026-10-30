import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Accounts screen (approved prototype group 4, R-MGMT-1, R-MGMT-9, R-ACC-1…5, D48, D55):
/// page search, sort and currency filter, groups as folders with the sum of their accounts in a
/// native outline list (a line between rows reorders, a highlighted row moves into a group or,
/// on an ungrouped account, makes a new group of both), editors as sheets (double-click / Return
/// / "Edit…"), and the "New account" split button in the toolbar.
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
      AccountsList(model: model)
        .frame(minWidth: 380, maxWidth: .infinity)
    }
    .navigationTitle("Accounts")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        NewAccountButton(model: model, currency: displayCurrency)
      }
    }
    .sheet(item: Binding(get: { model.sheet }, set: { if $0 == nil, model.sheet != nil { model.dismissSheet() } })) {
      sheet in
      switch sheet {
      case .account(let draft): AccountEditorSheet(model: model, initial: draft)
      case .group(let draft): AccountGroupEditorSheet(model: model, initial: draft)
      }
    }
    // Confirmations raised from the list; the editor sheets show their own.
    .sheet(
      item: Binding(
        get: { model.sheet == nil ? model.dialog : nil },
        set: { if $0 == nil, model.sheet == nil, model.dialog != nil { model.cancelDialog() } })
    ) { dialog in
      AccountsDialog(model: model, dialog: dialog)
    }
    .sheet(
      item: Binding(
        get: { model.groupPrompt }, set: { if $0 == nil, model.groupPrompt != nil { model.cancelGroupPrompt() } })
    ) { prompt in
      AccountGroupNameSheet(model: model, prompt: prompt)
    }
    .onChange(of: displayCurrency, initial: true) { _, currency in model.setDisplayCurrency(currency) }
    .task {
      if model.phase == .idle { await model.load() }
      #if DEBUG
        await openDebugSheet()
      #endif
    }
  }

  #if DEBUG
    /// UI checks (in-app snapshot): `-AbacusOpenSheet newAccount|editAccount|newGroup|editGroup|
    /// groupPrompt` opens that sheet once the page has loaded.
    private func openDebugSheet() async {
      guard let which = UserDefaults.standard.string(forKey: "AbacusOpenSheet") else { return }
      for _ in 0..<50 where model.phase != .loaded || model.rows.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
      let accounts = model.rows.filter { !$0.isGroup }
      switch which {
      case "newAccount": model.newAccount(currency: displayCurrency)
      case "editAccount": if let row = accounts.first { model.edit(row.id) }
      case "newGroup": model.newGroup()
      case "editGroup": if let row = model.rows.first(where: \.isGroup) { model.edit(row.id) }
      case "groupPrompt":
        let loose = accounts.filter { !$0.isChild }
        if loose.count >= 2 { await model.drop(loose[1].id, on: loose[0].id, position: .onto) }
      default: break
      }
    }
  #endif
}

/// "New account | ˅" (D55): the main part creates an account (in the selected row's group, as
/// before); the menu lists "New account in <group>" for every group A–Z and "New group…".
struct NewAccountButton: View {
  let model: AccountsModel
  let currency: Currency

  var body: some View {
    Menu {
      ForEach(model.groupOptions) { group in
        Button("New account in \(group.name)") { model.newAccount(currency: currency, inGroup: group.id) }
      }
      if !model.groupOptions.isEmpty { Divider() }
      Button("New group…") { model.newGroup() }
    } label: {
      Label("New account", systemImage: "plus")
        .labelStyle(.titleAndIcon)
    } primaryAction: {
      model.newAccount(currency: currency)
    }
    .menuIndicator(.visible)
    .fixedSize()
    .help("New account; the arrow lists the groups and New group")
  }
}

/// The archive / delete confirmations (R-ACC-4, R-ACC-5, R-MGMT-9).
struct AccountsDialog: View {
  let model: AccountsModel
  let dialog: ManageDialog

  var body: some View {
    ManageDialogView(dialog: dialog, onCancel: model.cancelDialog) {
      Task { await model.confirmDialog() }
    }
  }
}

/// Search, currency filter, sort, "Show archived accounts" and the outline (R-MGMT-1,
/// R-MGMT-9, R-MGMT-11, D55).
struct AccountsList: View {
  let model: AccountsModel

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
      OutlineList(
        nodes: nodes,
        selection: model.selectedIDs,
        rowHeight: 44,
        onSelect: { model.select(ids: $0) },
        onActivate: { model.edit($0) },
        canDrop: { model.canDrop($0.moving, on: $0.target, position: $0.position) },
        onDrop: { drop in Task { await model.drop(drop.moving, on: drop.target, position: drop.position) } }
      )
      .padding(.horizontal, 8)
      .overlay {
        if let message = model.emptySearchMessage {
          Text(message).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var nodes: [OutlineNode] {
    OutlineTree.nodes(model.rows, isChild: \.isChild) { row, children in
      OutlineNode(id: row.id, signature: row, children: children) { AccountRowView(row: row) }
    }
  }
}

/// A group (folder tile, name, "3 accounts", the sum in the display currency) or an account
/// (tile with the currency symbol, name, "Kind · CUR", balance); the outline indents accounts
/// inside a group.
struct AccountRowView: View {
  let row: AccountRow

  var body: some View {
    HStack(spacing: 12) {
      ManageGrip()
      tile
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.name).fontWeight(row.isGroup ? .semibold : .medium).lineLimit(1)
          if row.isArchived {
            Text("Archived")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(ManagePalette.badge, in: .capsule)
          }
        }
        Text(row.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      Text(row.balanceText)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(row.isNegative ? ManagePalette.negative : Color.primary)
        .padding(.trailing, 8)
    }
    .opacity(row.matchesSearch ? 1 : 0.55)
    .font(.system(size: 13))
    .frame(maxHeight: .infinity)
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

// MARK: - Sheets

/// The account editor (D55, R-ACC-1, R-ACC-4, R-ACC-5): name, kind, currency (fixed after the
/// first transaction), opening balance and date, group, colour, IBAN, current balance; Archive…
/// / Unarchive and Delete… on the left, Cancel and Save on the right (R-MGMT-10). The form is
/// this sheet's own state; the model sees it on Save.
struct AccountEditorSheet: View {
  let model: AccountsModel
  @State private var draft: AccountDraft
  /// The form as opened: the validation message waits for the first edit.
  private let initial: AccountDraft

  init(model: AccountsModel, initial: AccountDraft) {
    self.model = model
    self.initial = initial
    _draft = State(initialValue: initial)
  }

  private var title: String {
    if draft.isNew { return "New account" }
    return model.account(draft.id)?.name ?? draft.name
  }

  var body: some View {
    ManageEditorSheet(
      title: title,
      message: draft != initial ? model.validationMessage(draft) : nil,
      error: model.errorMessage,
      saveTitle: draft.isNew ? "Create" : "Save",
      canSave: model.canSave(draft),
      onCancel: model.dismissSheet,
      onSave: { Task { await model.save(draft) } }
    ) {
      AccountFields(model: model, draft: $draft)
    } actions: {
      if !draft.isNew, model.account(draft.id) != nil {
        Button(model.archiveTitle) { Task { await model.archiveOrUnarchive() } }
        Button("Delete…", role: .destructive) { model.requestDelete() }
          .disabled(!model.canDelete)
          .help(model.deleteHint)
      }
    }
    .sheet(
      item: Binding(get: { model.dialog }, set: { if $0 == nil, model.dialog != nil { model.cancelDialog() } })
    ) { dialog in
      AccountsDialog(model: model, dialog: dialog)
    }
  }
}

struct AccountFields: View {
  let model: AccountsModel
  @Binding var draft: AccountDraft

  var body: some View {
    ManageField("Name") {
      TextField("Name", text: $draft.name, prompt: Text("e.g. PKO Personal"))
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
    }
    HStack(alignment: .top, spacing: 12) {
      ManageField("Kind") {
        Picker("Kind", selection: $draft.kind) {
          Section("Assets") {
            ForEach(ManageText.assetKinds, id: \.self) { Text(ManageText.kindTitle($0)).tag($0) }
          }
          Section("Liabilities") {
            ForEach(ManageText.liabilityKinds(offeredFor: draft.kind), id: \.self) {
              Text(ManageText.kindTitle($0)).tag($0)
            }
          }
        }
        .labelsHidden()
      }
      ManageField("Currency") {
        if model.isCurrencyLocked(draft) {
          Text(draft.currency.rawValue)
            .padding(.vertical, 4)
            .help("Fixed after the first transaction")
        } else {
          Picker("Currency", selection: $draft.currency) {
            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
    }
    Text("The currency is fixed after the first transaction.")
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    HStack(alignment: .top, spacing: 12) {
      ManageField("Opening balance") {
        TextField("Opening balance", text: $draft.openingBalance)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
      }
      ManageField("Opening date") {
        DatePicker("Opening date", selection: $draft.openingDate, displayedComponents: .date)
          .labelsHidden()
          .datePickerStyle(.field)
      }
    }
    ManageField("Group") {
      Picker("Group", selection: $draft.groupID) {
        Text("None (top level)").tag(AccountGroup.ID?.none)
        ForEach(model.groupOptions) { Text($0.name).tag(Optional($0.id)) }
      }
      .labelsHidden()
    }
    ManageField("Colour") {
      ManageColorField(hex: $draft.colorHex)
    }
    ManageField("Bank account number (IBAN)") {
      TextField("IBAN", text: $draft.iban, prompt: Text("Used to recognise transfers in bank imports"))
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
    }
    if model.offersDebts {
      AccountDebtSection(model: model, draft: $draft)
    }
    if !draft.isNew, model.selection == draft.id, let balance = model.balanceText {
      ManageCard {
        HStack {
          Text("Current balance").foregroundStyle(.secondary)
          Spacer()
          Text(balance)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(model.isBalanceNegative ? ManagePalette.negative : Color.primary)
        }
        Text(model.deleteHint).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }
}

/// The group editor (R-MGMT-9, D55): name, optional colour, its accounts and their sum; Delete
/// group… on the left (its accounts move to the top level).
struct AccountGroupEditorSheet: View {
  let model: AccountsModel
  @State private var draft: AccountGroupDraft
  /// The form as opened: the validation message waits for the first edit.
  private let initial: AccountGroupDraft

  init(model: AccountsModel, initial: AccountGroupDraft) {
    self.model = model
    self.initial = initial
    _draft = State(initialValue: initial)
  }

  private var title: String {
    if draft.isNew { return "New group" }
    return model.group(draft.id)?.name ?? draft.name
  }

  var body: some View {
    ManageEditorSheet(
      title: title,
      message: draft != initial ? model.validationMessage(draft) : nil,
      error: model.errorMessage,
      saveTitle: draft.isNew ? "Create" : "Save",
      canSave: model.canSave(draft),
      onCancel: model.dismissSheet,
      onSave: { Task { await model.save(draft) } }
    ) {
      ManageField("Name") {
        TextField("Name", text: $draft.name, prompt: Text("e.g. Monobank, PKO"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
      ManageField("Colour") {
        ManageColorField(hex: $draft.colorHex)
      }
      if !draft.isNew, let summary = model.selectedGroupSummary, let sum = model.selectedGroupSumText {
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
      Text(
        draft.isNew
          ? "Drag accounts onto the group to move them in, or pick the group in an account's form."
          : "Deleting the group moves its accounts to the top level."
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } actions: {
      if !draft.isNew, model.group(draft.id) != nil {
        Button("Delete group…", role: .destructive) { model.requestDeleteGroup() }
      }
    }
    .sheet(
      item: Binding(get: { model.dialog }, set: { if $0 == nil, model.dialog != nil { model.cancelDialog() } })
    ) { dialog in
      AccountsDialog(model: model, dialog: dialog)
    }
  }
}

/// An account dropped onto an ungrouped account (D55): the new group's name, suggested from the
/// target's first word. Cancel leaves both accounts where they were.
struct AccountGroupNameSheet: View {
  let model: AccountsModel
  let prompt: AccountGroupPrompt
  @State private var name: String

  init(model: AccountsModel, prompt: AccountGroupPrompt) {
    self.model = model
    self.prompt = prompt
    _name = State(initialValue: prompt.defaultName)
  }

  private var names: String {
    let target = model.account(prompt.target)?.name ?? ""
    let moving = model.account(prompt.moving)?.name ?? ""
    return "“\(target)” and “\(moving)”"
  }

  var body: some View {
    ManageEditorSheet(
      title: "New group",
      message: nil,
      error: nil,
      saveTitle: "Create group",
      canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
      width: 380,
      onCancel: model.cancelGroupPrompt,
      onSave: { Task { await model.confirmGroupPrompt(name: name) } }
    ) {
      Text("A new group will hold \(names).")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ManageField("Group name") {
        TextField("Group name", text: $name)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
    } actions: {
      EmptyView()
    }
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

// MARK: - Debt section (R-DEBT-17)

/// The editor's "Debt" section: which debt (person) this account belongs to, a searchable list
/// with "None" and "New debt…". Saving links, moves or unlinks through the debt repository.
struct AccountDebtSection: View {
  let model: AccountsModel
  @Binding var draft: AccountDraft
  @State private var showingList = false
  @State private var search = ""

  private var buttonTitle: String {
    switch draft.debt {
    case .none: "None"
    case .existing(let id): model.debt(id)?.personName ?? "Unknown debt"
    case .new(let name): name.trimmingCharacters(in: .whitespaces).isEmpty ? "New debt…" : "New debt: \(name)"
    }
  }

  var body: some View {
    ManageField("Debt") {
      Button {
        search = ""
        showingList = true
      } label: {
        HStack {
          Text(buttonTitle)
          Spacer()
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
      }
      .accessibilityLabel("Debt")
      .popover(isPresented: $showingList, arrowEdge: .bottom) { list }
      if case .new(let name) = draft.debt {
        TextField(
          "Person", text: Binding(get: { name }, set: { draft.debt = .new(name: $0) }),
          prompt: Text("Name of the person"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
      if let notice = model.debtNotice(draft) {
        Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      if let hint = model.debtRoleHint(draft) {
        Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Search debts", text: $search).textFieldStyle(.roundedBorder)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          row("None", selected: draft.debt == .none) { draft.debt = .none }
          ForEach(model.debtOptions(matching: search)) { debt in
            row(
              debt.isSettled ? "\(debt.personName) (settled)" : debt.personName,
              selected: draft.debt == .existing(debt.id)
            ) { draft.debt = .existing(debt.id) }
          }
          Divider().padding(.vertical, 4)
          row("New debt…", selected: false) {
            let typed = search.trimmingCharacters(in: .whitespaces)
            draft.debt = .new(name: typed.isEmpty ? draft.name : typed)
          }
        }
      }
      .frame(maxHeight: 220)
    }
    .padding(10)
    .frame(width: 260)
  }

  private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button {
      action()
      showingList = false
    } label: {
      HStack {
        Text(title)
        Spacer()
        if selected { Image(systemName: "checkmark") }
      }
      .contentShape(Rectangle())
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
  }
}
