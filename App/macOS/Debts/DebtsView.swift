import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Debts tab (R-DEBT-5): totals and people on the left (page search, Active/Settled), the
/// selected person's debts on the right — balance per currency with direction, due date, note,
/// records with their accounts, totals; add / edit / delete records, edit the debt, mark it
/// settled. Forms keep Save bottom-right (R-MGMT-10).
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
            .help("A person and a currency")
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageSearchField(text: $model.search, prompt: "Search people")
        .padding(.horizontal, 16)
        .padding(.top, 12)
      let summary = model.summary
      HStack(spacing: 16) {
        DebtTotal(title: "Owed to you", money: summary.owedToMe, color: DebtStyle.owedToMe)
        DebtTotal(title: "You owe", money: summary.iOwe, color: DebtStyle.iOwe)
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
          description: Text(model.search.isEmpty ? "“New debt” adds a person and a currency." : "Nothing matches the search."))
        .frame(maxHeight: .infinity)
      } else {
        List(selection: $model.selectedPerson) {
          ForEach(model.people) { person in
            DebtPersonRowView(person: person).tag(person.id)
          }
        }
        .listStyle(.inset)
      }
    }
  }
}

struct DebtTotal: View {
  let title: String
  let money: Money
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(DashboardFormat().money(money)).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
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
        ForEach(person.balances) { balance in
          DebtBalanceLabel(balance: balance, compact: true)
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

  var body: some View {
    if let name = model.selectedPersonName {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(spacing: 10) {
            DebtAvatar(name: name)
            Text(name).font(.title2.weight(.semibold))
            Spacer()
            Button("Add currency", systemImage: "plus") { model.newDebt() }
              .help("Another debt with this person in another currency")
          }
          ForEach(model.selectedDetails) { detail in
            DebtCard(model: model, detail: detail)
          }
        }
        .padding(20)
      }
    } else {
      ContentUnavailableView("Select a person", systemImage: "person.2", description: Text("Their debts and records show here."))
    }
  }
}

struct DebtCard: View {
  @Bindable var model: DebtsModel
  let detail: DebtsModel.DebtDetail

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(detail.debt.currency.rawValue)
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.quaternary, in: .capsule)
            if detail.debt.isSettled {
              Text("Settled").font(.caption).foregroundStyle(.secondary)
            }
            if !detail.debt.countsInNetWorth {
              Text("Not in net worth").font(.caption).foregroundStyle(.secondary)
            }
          }
          if let due = detail.dueText {
            Label(due, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
          }
          if !detail.debt.note.isEmpty {
            Text(detail.debt.note).font(.callout).foregroundStyle(.secondary)
          }
        }
        Spacer()
        DebtBalanceLabel(balance: detail.balance)
      }
      if let totals = detail.totalsText {
        Text(totals).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Add record", systemImage: "plus") { model.newRecord(debtID: detail.debt.id) }
          .buttonStyle(.borderedProminent)
          .disabled(detail.debt.isSettled)
        Button("Edit debt…") { model.editDebt(detail.debt.id) }
        Spacer()
        if detail.debt.isSettled {
          Button("Reopen") { Task { await model.setSettled(detail.debt.id, false) } }
        } else {
          Button("Mark settled") { Task { await model.setSettled(detail.debt.id, true) } }
            .disabled(!detail.canSettle)
            .help(detail.canSettle ? "Moves the debt to Settled" : "Only a zero balance can be settled")
        }
      }
      if detail.records.isEmpty {
        Text("No records yet.").font(.callout).foregroundStyle(.secondary)
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
        .foregroundStyle(row.increasesBalance ? DebtStyle.owedToMe : DebtStyle.iOwe)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

// MARK: - Forms

struct DebtFormSheet: View {
  @Bindable var model: DebtsModel
  @State private var confirmDelete = false

  var body: some View {
    if let draft = Binding($model.debtDraft) {
      VStack(alignment: .leading, spacing: 0) {
        Text(draft.wrappedValue.id == nil ? "New debt" : "Edit debt").font(.headline).padding([.horizontal, .top], 20)
        Form {
          TextField("Person", text: draft.personName)
          Picker("Currency", selection: draft.currency) {
            ForEach(Currency.displayOrder, id: \.self) { Text($0.rawValue).tag($0) }
          }
          .disabled(model.debtCurrencyLocked)
          Toggle("Due date", isOn: draft.hasDueDay)
          if draft.wrappedValue.hasDueDay {
            DatePicker("Due", selection: draft.dueDate, displayedComponents: .date)
          }
          TextField("Note", text: draft.note, axis: .vertical).lineLimit(2...4)
          Toggle("Count in net worth", isOn: draft.countsInNetWorth)
            .help("Owed to you counts as an asset, what you owe as a liability")
        }
        .formStyle(.grouped)
        if let issue = model.debtDraftIssue ?? model.errorMessage {
          Text(issue).font(.caption).foregroundStyle(ManagePalette.negative).padding(.horizontal, 20)
        }
        HStack {
          if let id = draft.wrappedValue.id {
            Button("Delete…", role: .destructive) { confirmDelete = true }
              .foregroundStyle(ManagePalette.destructive)
              .confirmationDialog("Delete this debt and all its records?", isPresented: $confirmDelete) {
                Button("Delete debt", role: .destructive) { Task { await model.deleteDebt(id) } }
              } message: {
                Text("Their transactions on your accounts are deleted too.")
              }
          }
          Spacer()
          Button("Cancel") { model.debtDraft = nil }
            .keyboardShortcut(.cancelAction)
          Button("Save") { Task { await model.saveDebtDraft() } }
            .keyboardShortcut(.defaultAction)
            .disabled(model.debtDraftIssue != nil)
        }
        .padding(20)
      }
      .frame(width: 420)
    }
  }
}

struct DebtRecordFormSheet: View {
  @Bindable var model: DebtsModel
  @State private var confirmDelete = false

  var body: some View {
    if let draft = Binding($model.recordDraft) {
      let currency = model.recordDebtCurrency?.rawValue ?? ""
      VStack(alignment: .leading, spacing: 0) {
        Text(draft.wrappedValue.recordID == nil ? "New record" : "Edit record").font(.headline)
          .padding([.horizontal, .top], 20)
        Form {
          Picker("Record", selection: Binding(get: { draft.wrappedValue.kind }, set: { model.setRecordKind($0) })) {
            ForEach(DebtRecordKind.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          DatePicker("Day", selection: draft.date, displayedComponents: .date)
          LabeledContent("Amount") {
            HStack {
              TextField("Amount", text: draft.amount).labelsHidden().multilineTextAlignment(.trailing)
              Text(currency).foregroundStyle(.secondary)
            }
          }
          if draft.wrappedValue.kind.movesMoney {
            Picker("Account", selection: draft.accountID) {
              Text("No account").tag(Account.ID?.none)
              AccountPickerItems(sections: model.accountSections) { account in
                Text("\(account.name) (\(account.currency.rawValue))").tag(Account.ID?.some(account.id))
              }
            }
            if model.recordNeedsAccountAmount, let account = model.recordAccount {
              LabeledContent("Amount on account") {
                HStack {
                  TextField(model.suggestedAccountAmount ?? "Amount", text: draft.accountAmount)
                    .labelsHidden().multilineTextAlignment(.trailing)
                  Text(account.currency.rawValue).foregroundStyle(.secondary)
                }
              }
            }
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
              } message: {
                Text("Its transaction on your account is deleted too.")
              }
          }
          Spacer()
          Button("Cancel") { model.recordDraft = nil }
            .keyboardShortcut(.cancelAction)
          Button("Save") { Task { await model.saveRecordDraft() } }
            .keyboardShortcut(.defaultAction)
            .disabled(model.recordDraftIssue != nil)
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
  static let owedToMe = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(red: 0.42, green: 0.85, blue: 0.55, alpha: 1) : NSColor(red: 0.10, green: 0.50, blue: 0.25, alpha: 1)
  })
  static let iOwe = ManagePalette.negative

  static func color(_ balance: DebtsModel.BalanceText) -> Color {
    balance.isZero ? .secondary : balance.owesMe ? owedToMe : iOwe
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
      case "record": if let debt = model.selectedDetails.first { model.newRecord(debtID: debt.id) }
      case "debt": if let debt = model.selectedDetails.first { model.editDebt(debt.id) }
      default: break
      }
    }
  }
#endif

#Preview("Debts") {
  DebtsView(model: DebtsModel(dependencies: .preview()), displayCurrency: .UAH)
    .frame(width: 1100, height: 720)
}
