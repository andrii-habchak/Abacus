import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Debts tab (R-DEBT-5, R-DEBT-21): totals and people on the left (page search,
/// Active/Settled, right-click menu), the selected person's debt on the right — header with
/// "Edit debt" / "Show transactions", linked accounts, hints, a block per currency with its manual
/// records. Money they owe me is shown negative and red, money I owe positive and green (D61, via
/// `DebtSign`). Forms keep Save bottom-right (R-MGMT-10).
struct DebtsView: View {
  @Bindable var model: DebtsModel
  var displayCurrency: Currency

  var body: some View {
    content
      .navigationTitle("Debts")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("New debt", systemImage: "plus") { model.newDebt() }
            .labelStyle(.titleAndIcon)
            .help("A person, with the accounts that hold the money")
        }
      }
      .sheet(isPresented: Binding(get: { model.debtDraft != nil }, set: { if !$0 { model.debtDraft = nil } })) {
        DebtFormSheet(model: model)
      }
      .sheet(isPresented: Binding(get: { model.recordDraft != nil }, set: { if !$0 { model.recordDraft = nil } })) {
        DebtRecordFormSheet(model: model)
      }
      .onChange(of: displayCurrency, initial: true) { _, currency in model.displayCurrency = currency }
      .task {
        if model.phase == .idle { await model.load() }
        #if DEBUG
          DebtsDebugLaunch.apply(to: model)
        #endif
      }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .failed(let message):
      ContentUnavailableView {
        Label("Debts", systemImage: "person.2")
      } description: {
        Text(message)
      } actions: {
        Button("Try again") { Task { await model.load() } }
      }
    case .idle, .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      HStack(spacing: 0) {
        DebtPeopleList(model: model)
          .frame(width: 320)
        Divider()
        DebtPersonDetail(model: model)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

// MARK: - People

struct DebtPeopleList: View {
  @Bindable var model: DebtsModel
  @State private var deleteTarget: DebtDeleteTarget?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageSearchField(text: $model.search, prompt: "Search people")
        .padding(.horizontal, 16)
        .padding(.top, 12)
      HStack(spacing: 16) {
        DebtTotal(title: DebtSign.lentTitle, text: model.lentTotalText, color: DebtStyle.lent)
        DebtTotal(title: DebtSign.borrowedTitle, text: model.borrowedTotalText, color: DebtStyle.borrowed)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      Picker("Show", selection: $model.filter) {
        ForEach(DebtsModel.Filter.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      if model.people.isEmpty {
        ContentUnavailableView(
          model.filter == .active ? "No open debts" : "No settled debts", systemImage: "person.2",
          description: Text(model.search.isEmpty ? "“New debt” adds a person." : "Nothing matches the search."))
        .frame(maxHeight: .infinity)
      } else {
        List(selection: $model.selectedPerson) {
          ForEach(model.people) { person in
            DebtPersonRowView(person: person).tag(person.id)
              .contextMenu {
                DebtContextMenu(
                  model: model, debtID: person.debtID,
                  actions: model.rowActions(for: person.debtID) ?? .init(isSettled: person.isSettled, canToggleSettled: false),
                  onEdit: { model.editDebt(person.debtID) },
                  onDelete: { deleteTarget = DebtDeleteTarget(id: person.debtID, name: person.name) })
              }
          }
        }
        .listStyle(.inset)
      }
    }
    .confirmDebtDelete($deleteTarget) { id in Task { await model.deleteDebt(id) } }
  }
}

/// The debt a delete confirmation is about.
struct DebtDeleteTarget: Identifiable, Equatable {
  let id: Debt.ID
  let name: String
}

extension View {
  /// "Delete" asks first: the debt and its manual records go, its accounts and their transactions
  /// stay (R-DEBT-21).
  func confirmDebtDelete(_ target: Binding<DebtDeleteTarget?>, perform: @escaping (Debt.ID) -> Void) -> some View {
    confirmationDialog(
      "Delete this debt?",
      isPresented: Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } }),
      titleVisibility: .visible, presenting: target.wrappedValue
    ) { item in
      Button("Delete \(item.name)", role: .destructive) { perform(item.id) }
    } message: { item in
      Text("\(item.name) and the manual records are deleted. The linked accounts and their transactions stay.")
    }
  }
}

/// Edit, Show transactions, Mark settled / Reopen, Delete (R-DEBT-21): the right-click menu of a
/// debt in the Debts list and on the dashboard widget.
struct DebtContextMenu: View {
  let model: DebtsModel
  let debtID: Debt.ID
  let actions: DebtsModel.RowActions
  var onEdit: () -> Void
  var onDelete: () -> Void

  var body: some View {
    Button("Edit…", action: onEdit)
    Button("Show transactions") { model.showTransactions(debtID) }
    Button(actions.settledTitle) { Task { await model.setSettled(debtID, !actions.isSettled) } }
      .disabled(!actions.canToggleSettled)
    Divider()
    Button("Delete…", role: .destructive, action: onDelete)
  }
}

struct DebtTotal: View {
  let title: String
  let text: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(text).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DebtPersonRowView: View {
  let person: DebtsModel.PersonRow

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      DebtAvatar(name: person.name)
      VStack(alignment: .leading, spacing: 3) {
        Text(person.name).font(.body.weight(.medium)).lineLimit(1)
        if let detail = person.detail {
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        if let total = person.total {
          Text((person.isApproximate ? "≈ " : "") + total.amountText)
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(DebtStyle.color(total))
            .help(person.isApproximate ? "All open balances in the display currency at today's rates" : "")
        } else {
          Text("No rate").font(.callout).foregroundStyle(.secondary)
            .help("A rate to the display currency is missing; refresh the rates")
        }
        if let secondary = person.secondaryText {
          Text(secondary).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
      }
    }
    .padding(.vertical, 4)
  }
}

struct DebtAvatar: View {
  let name: String

  var body: some View {
    Text(String(name.prefix(1)).uppercased())
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 28, height: 28)
      .background(Circle().fill(DebtStyle.avatar(name)))
  }
}

struct DebtBalanceLabel: View {
  let balance: DebtsModel.BalanceText
  var compact = false

  var body: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text(balance.amountText)
        .font((compact ? Font.callout : .title2).weight(.semibold).monospacedDigit())
        .foregroundStyle(DebtStyle.color(balance))
      Text(balance.directionText)
        .font(compact ? .caption2 : .caption)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Detail

struct DebtPersonDetail: View {
  @Bindable var model: DebtsModel
  @State private var deleteTarget: DebtDeleteTarget?

  var body: some View {
    if let header = model.selectedHeader {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          DebtHeaderView(model: model, header: header, onDelete: {
            deleteTarget = DebtDeleteTarget(id: header.debtID, name: header.name)
          })
          let notices = model.selectedNotices
          if !notices.isEmpty {
            DebtNoticesView(notices: notices)
          }
          let accounts = model.selectedBreakdown
          if !accounts.isEmpty {
            DebtAccountsView(rows: accounts)
          }
          ForEach(model.selectedDetails) { detail in
            DebtCard(model: model, detail: detail)
          }
        }
        .padding(20)
      }
      .confirmDebtDelete($deleteTarget) { id in Task { await model.deleteDebt(id) } }
    } else {
      ContentUnavailableView("Select a person", systemImage: "person.2", description: Text("Their debts and records show here."))
    }
  }
}

/// The whole-debt header (R-DEBT-21): name, due date, note, the person's total, and the actions
/// "Edit debt", "Show transactions", Mark settled / Reopen. Per-currency things live in the blocks
/// below, not here.
struct DebtHeaderView: View {
  @Bindable var model: DebtsModel
  let header: DebtsModel.Header
  var onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        DebtAvatar(name: header.name)
        VStack(alignment: .leading, spacing: 4) {
          Text(header.name).font(.title2.weight(.semibold))
          HStack(spacing: 8) {
            if header.isSettled { Text("Settled").font(.caption).foregroundStyle(.secondary) }
            if let due = header.dueText { Label(due, systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
            if !header.countsInNetWorth { Text("Not in net worth").font(.caption).foregroundStyle(.secondary) }
          }
          if !header.note.isEmpty {
            Text(header.note).font(.callout).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if let total = model.selectedTotal {
          DebtPersonTotalView(total: total).padding(.trailing, 8)
        }
      }
      HStack {
        Button("Edit debt", systemImage: "pencil") { model.editDebt(header.debtID) }
          .buttonStyle(.borderedProminent)
          .help("Name, due date, note, net worth and the linked accounts")
        Button("Show transactions", systemImage: "list.bullet") { model.showTransactions(header.debtID) }
          .help("The Transactions list filtered to this debt's accounts")
        Spacer()
        if header.isSettled {
          Button("Reopen") { Task { await model.setSettled(header.debtID, false) } }
        } else {
          Button("Mark settled") { Task { await model.setSettled(header.debtID, true) } }
            .disabled(!header.canSettle)
            .help(header.canSettle ? "Moves the debt to Settled" : "Only a zero balance can be settled")
        }
        Button("Delete…", role: .destructive, action: onDelete)
          .foregroundStyle(ManagePalette.destructive)
      }
    }
  }
}

/// The person's open balances summed in the display currency (R-DEBT-15); "≈ total in UAH" when
/// some balance was converted at today's rate.
struct DebtPersonTotalView: View {
  let total: DebtsModel.PersonTotal

  var body: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text(total.caption).font(.caption).foregroundStyle(.secondary)
      if let balance = total.balance {
        Text(balance.amountText)
          .font(.title3.weight(.semibold).monospacedDigit())
          .foregroundStyle(DebtStyle.color(balance))
        Text(balance.directionText).font(.caption).foregroundStyle(.secondary)
      } else {
        Text("No rate").font(.title3).foregroundStyle(.secondary)
          .help("A rate to the display currency is missing; refresh the rates")
      }
    }
    .help(total.isApproximate ? "All balances in the display currency at today's rates" : "")
  }
}

/// Non-blocking hints (R-DEBT-20, R-DEBT-21): nothing is merged or changed by them.
struct DebtNoticesView: View {
  let notices: [DebtsModel.Notice]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(notices) { notice in
        Label {
          Text(notice.text).font(.callout).foregroundStyle(.secondary)
        } icon: {
          Image(systemName: notice.kind == .duplicate ? "exclamationmark.triangle" : "clock")
            .foregroundStyle(notice.kind == .duplicate ? Color.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(12)
    .background(ManagePalette.inspectorBackground, in: .rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ManagePalette.border))
  }
}

/// R-DEBT-17, R-DEBT-21: each linked account of the person with its role, currency, opening
/// balance and balance (display sign).
struct DebtAccountsView: View {
  let rows: [DebtsModel.AccountBreakdownRow]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Accounts").font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        GridRow {
          Text("Account")
          Text("Role")
          Text("Currency")
          Text("Opening").gridColumnAlignment(.trailing)
          Text("Balance").gridColumnAlignment(.trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        ForEach(rows) { row in
          GridRow {
            VStack(alignment: .leading, spacing: 0) {
              Text(row.name).lineLimit(1)
              Text(row.transactionsText).font(.caption2).foregroundStyle(.secondary)
            }
            Text(row.roleTitle).font(.caption).foregroundStyle(.secondary)
            Text(row.currency.rawValue).font(.caption).foregroundStyle(.secondary)
            Text(row.openingText).foregroundStyle(row.openingText == "—" ? Color.secondary : Color.primary)
            Text(row.balance.amountText).foregroundStyle(DebtStyle.color(row.balance))
          }
          .font(.callout.monospacedDigit())
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ManagePalette.inspectorBackground, in: .rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ManagePalette.border))
  }
}

/// One currency of the debt: its balance and manual records (forgive, adjustments).
struct DebtCard: View {
  @Bindable var model: DebtsModel
  let detail: DebtsModel.DebtDetail

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        Text(detail.currency.rawValue)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.quaternary, in: .capsule)
        Spacer()
        DebtBalanceLabel(balance: detail.balance)
      }
      if let totals = detail.totalsText {
        Text(totals).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Add record", systemImage: "plus") { model.newRecord(debtID: detail.debt.id, currency: detail.currency) }
          .buttonStyle(.bordered)
          .disabled(detail.debt.isSettled)
          .help("A manual record in \(detail.currency.rawValue): forgive, adjustment")
        Spacer()
      }
      if detail.records.isEmpty {
        Text("No manual records.").font(.callout).foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(detail.records) { row in
            DebtRecordRowView(row: row)
              .contentShape(Rectangle())
              .onTapGesture(count: 2) { model.editRecord(row.id) }
              .contextMenu {
                Button("Edit…") { model.editRecord(row.id) }
                Button("Delete", role: .destructive) { Task { await model.deleteRecord(row.id) } }
              }
            if row.id != detail.records.last?.id { Divider() }
          }
        }
        .background(ManagePalette.card, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ManagePalette.border))
      }
    }
    .padding(16)
    .background(ManagePalette.inspectorBackground, in: .rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ManagePalette.border))
  }
}

struct DebtRecordRowView: View {
  let row: DebtsModel.RecordRow

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(row.dayText).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.kindTitle).font(.callout.weight(.medium))
        HStack(spacing: 6) {
          Text(row.accountText)
          if let report = row.reportText {
            Text(report)
              .padding(.horizontal, 5)
              .background(ManagePalette.match, in: .capsule)
              .foregroundStyle(ManagePalette.matchText)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        if !row.note.isEmpty {
          Text(row.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer()
      Text(row.amountText)
        .font(.callout.weight(.semibold).monospacedDigit())
        .foregroundStyle(row.increasesBalance ? DebtStyle.lent : DebtStyle.borrowed)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

// MARK: - Forms

struct DebtFormSheet: View {
  @Bindable var model: DebtsModel
  @State private var confirmDelete = false
  @State private var accountSearch = ""

  var body: some View {
    // Not `Binding($model.debtDraft)`: Save, Delete and Escape set the draft to nil while the
    // sheet's fields are still on screen; a force-unwrapped binding crashed there (S1, D54).
    if let shown = model.debtDraft {
      let draft = presentBinding({ model.debtDraft }, { model.debtDraft = $0 }, fallback: shown)
      VStack(alignment: .leading, spacing: 0) {
        Text(draft.wrappedValue.id == nil ? "New debt" : "Edit debt").font(.headline).padding([.horizontal, .top], 20)
        // One scroll area between the fixed title and the fixed footer; sections stack in it
        // without height caps, so nothing is clipped or drawn over another row.
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
              TextField("Person", text: draft.personName)
              Toggle("Due date", isOn: draft.hasDueDay)
              if draft.wrappedValue.hasDueDay {
                DatePicker("Due", selection: draft.dueDate, displayedComponents: .date)
              }
              TextField("Note", text: draft.note, axis: .vertical).lineLimit(2...4)
              Toggle("Count in net worth", isOn: draft.countsInNetWorth)
                .help("What you lent counts as an asset, what you borrowed as a liability")
            }
            .textFieldStyle(.roundedBorder)
            DebtAccountPicker(model: model, search: $accountSearch)
          }
          .padding(20)
        }
        if let issue = model.debtDraftIssue ?? model.errorMessage {
          Text(issue).font(.caption).foregroundStyle(ManagePalette.negative).padding(.horizontal, 20).padding(.top, 8)
        }
        HStack {
          if let id = draft.wrappedValue.id {
            Button("Delete…", role: .destructive) { confirmDelete = true }
              .foregroundStyle(ManagePalette.destructive)
              .confirmationDialog("Delete this debt and its manual records?", isPresented: $confirmDelete) {
                Button("Delete debt", role: .destructive) { Task { await model.deleteDebt(id) } }
              } message: {
                Text("Its accounts and their transactions stay.")
              }
          }
          Spacer()
          Button("Cancel") { model.debtDraft = nil }
            .keyboardShortcut(.cancelAction)
          Button("Save") { Task { await model.saveDebtDraft() } }
            .keyboardShortcut(.defaultAction)
            .disabled(model.debtDraftIssue != nil || model.isSaving)
        }
        .padding(20)
      }
      .frame(width: 520, height: 640)
    }
  }
}

/// The account part of the debt dialog (R-DEBT-17, R-DEBT-21), three stacked sections inside the
/// sheet's single scroll area: "Linked accounts" (name, role, currency, opening balance in the
/// display sign, unlink), "Add accounts" (searchable; an account of another debt is disabled and
/// names that debt) and "Create account" (a virtual account in a chosen currency) in its own section.
struct DebtAccountPicker: View {
  @Bindable var model: DebtsModel
  @Binding var search: String

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      linked
      add
      create
    }
  }

  private var linked: some View {
    let rows = model.linkedAccountRows
    return VStack(alignment: .leading, spacing: 8) {
      Text("Linked accounts").font(.headline)
      Text("The person's accounts (never your own). The opening balance is negative when they owe you.")
        .font(.caption).foregroundStyle(.secondary)
      card {
        if rows.isEmpty {
          Text("No accounts linked yet.").font(.callout).foregroundStyle(.secondary).padding(12)
        }
        ForEach(rows) { row in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
              Text(row.name).lineLimit(1)
              Text("\(row.roleTitle) · \(row.currency.rawValue)\(row.isArchived ? " · archived" : "")")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextField("Opening", text: openingBinding(row.id))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .textFieldStyle(.roundedBorder)
              .help("Opening balance of this account; negative = they owe you")
            Button("Unlink", systemImage: "link.badge.minus") { model.toggleAccount(row.id) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("Unlink this account from the debt; the account and its transactions stay")
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          if row.id != rows.last?.id { Divider() }
        }
      }
    }
  }

  private var add: some View {
    let choices = model.addableAccountChoices(search: search)
    return VStack(alignment: .leading, spacing: 8) {
      Text("Add accounts").font(.headline)
      PageSearchField(text: $search, prompt: "Search accounts")
      card {
        if choices.isEmpty {
          Text("No accounts match.").font(.callout).foregroundStyle(.secondary).padding(12)
        }
        LazyVStack(spacing: 0) {
          ForEach(choices) { choice in
            Button {
              model.toggleAccount(choice.id)
            } label: {
              HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                  Text(choice.name).lineLimit(1)
                  Text(choice.disabledReason ?? "\(choice.kindTitle) · \(choice.currency.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !choice.isDisabled { Image(systemName: "plus.circle").foregroundStyle(.secondary) }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(choice.isDisabled)
            .opacity(choice.isDisabled ? 0.55 : 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if choice.id != choices.last?.id { Divider() }
          }
        }
      }
    }
  }

  private var create: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Create account").font(.headline)
      if let draft = model.debtDraft, !draft.newAccounts.isEmpty {
        VStack(spacing: 8) {
          ForEach(draft.newAccounts) { item in
            NewAccountRow(
              item: elementBinding(
                { model.debtDraft?.newAccounts ?? [] }, { model.debtDraft?.newAccounts = $0 }, id: item.id, fallback: item),
              onRemove: { model.removeNewAccount(item.id) })
          }
        }
      }
      Button("Create account", systemImage: "plus") { model.addNewAccount() }
        .help("A virtual account for this person, in a currency of your choice")
    }
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 0, content: content)
      .frame(maxWidth: .infinity)
      .background(ManagePalette.card, in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ManagePalette.border))
  }

  private func openingBinding(_ id: Account.ID) -> Binding<String> {
    Binding(
      get: { model.debtDraft?.openings[id] ?? "" },
      set: { model.debtDraft?.openings[id] = $0 })
  }
}

/// A virtual account to create: name (optional), currency, optional opening balance.
struct NewAccountRow: View {
  @Binding var item: DebtsModel.NewAccountDraft
  var onRemove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      TextField("Name (optional)", text: $item.name)
      Picker("Currency", selection: $item.currency) {
        ForEach(Currency.displayOrder, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .labelsHidden()
      .frame(width: 80)
      TextField("Opening", text: $item.opening)
        .multilineTextAlignment(.trailing)
        .frame(width: 90)
        .help("Opening balance; negative = they owe you")
      Button("Remove", systemImage: "minus.circle", action: onRemove)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .textFieldStyle(.roundedBorder)
  }
}

struct DebtRecordFormSheet: View {
  @Bindable var model: DebtsModel
  @State private var confirmDelete = false

  var body: some View {
    // See `DebtFormSheet`: the record draft becomes nil on Save, Delete and Escape (S1, D54).
    if let shown = model.recordDraft {
      let draft = presentBinding({ model.recordDraft }, { model.recordDraft = $0 }, fallback: shown)
      VStack(alignment: .leading, spacing: 0) {
        Text(draft.wrappedValue.recordID == nil ? "New record" : "Edit record").font(.headline)
          .padding([.horizontal, .top], 20)
        Form {
          Picker("Record", selection: Binding(get: { draft.wrappedValue.kind }, set: { model.setRecordKind($0) })) {
            ForEach(DebtRecordKind.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          DatePicker("Day", selection: draft.date, displayedComponents: .date)
          LabeledContent("Amount") {
            TextField("Amount", text: draft.amount).labelsHidden().multilineTextAlignment(.trailing)
          }
          Picker("Currency", selection: draft.currency) {
            ForEach(Currency.displayOrder, id: \.self) { Text($0.rawValue).tag($0) }
          }
          if let kind = model.recordReportKind {
            Toggle(kind == .expense ? "Count as expense" : "Count as income", isOn: draft.countsInReports)
              .help("Shown under the “Debts” category in monthly reports and the budget")
          }
          TextField("Note", text: draft.note, axis: .vertical).lineLimit(1...3)
        }
        .formStyle(.grouped)
        if let issue = model.errorMessage {
          Text(issue).font(.caption).foregroundStyle(ManagePalette.negative).padding(.horizontal, 20)
        }
        HStack {
          if let id = draft.wrappedValue.recordID {
            Button("Delete…", role: .destructive) { confirmDelete = true }
              .foregroundStyle(ManagePalette.destructive)
              .confirmationDialog("Delete this record?", isPresented: $confirmDelete) {
                Button("Delete record", role: .destructive) { Task { await model.deleteRecord(id) } }
              }
          }
          Spacer()
          Button("Cancel") { model.recordDraft = nil }
            .keyboardShortcut(.cancelAction)
          Button("Save") { Task { await model.saveRecordDraft() } }
            .keyboardShortcut(.defaultAction)
            .disabled(model.recordDraftIssue != nil || model.isSaving)
            .help(model.recordDraftIssue ?? "")
        }
        .padding(20)
      }
      .frame(width: 440)
    }
  }
}

// MARK: - Style

enum DebtStyle {
  /// Green: money I owe ("you borrowed", positive, D61).
  static let borrowed = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(red: 0.42, green: 0.85, blue: 0.55, alpha: 1) : NSColor(red: 0.10, green: 0.50, blue: 0.25, alpha: 1)
  })
  /// Red: money they owe me ("you lent", negative, D61).
  static let lent = ManagePalette.negative

  static func color(_ balance: DebtsModel.BalanceText) -> Color {
    switch balance.tone {
    case .settled: .secondary
    case .lent: lent
    case .borrowed: borrowed
    }
  }

  /// Colour of a stored-sign amount (nil = no rate).
  static func color(stored minor: Int64?) -> Color {
    switch DebtSign.tone(stored: minor ?? 0) {
    case .settled: .secondary
    case .lent: lent
    case .borrowed: borrowed
    }
  }

  static func avatar(_ name: String) -> Color {
    let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .brown]
    let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[sum % palette.count]
  }
}

#if DEBUG
  /// Launch options for screenshots: `-AbacusDebtsPerson <name>` selects a person,
  /// `-AbacusDebtsForm record|debt` opens a form on the selected person's first debt.
  enum DebtsDebugLaunch {
    @MainActor static func apply(to model: DebtsModel) {
      let defaults = UserDefaults.standard
      if let name = defaults.string(forKey: "AbacusDebtsPerson"),
        let person = model.people.first(where: { $0.name == name })
      {
        model.selectedPerson = person.id
      }
      switch defaults.string(forKey: "AbacusDebtsForm") {
      case "record": if let detail = model.selectedDetails.first { model.newRecord(debtID: detail.debt.id) }
      case "debt": if let detail = model.selectedDetails.first { model.editDebt(detail.debt.id) }
      default: break
      }
    }
  }
#endif

#Preview("Debts") {
  DebtsView(model: DebtsModel(dependencies: .preview()), displayCurrency: .UAH)
    .frame(width: 1100, height: 720)
}
