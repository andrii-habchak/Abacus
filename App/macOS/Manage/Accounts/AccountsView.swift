import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Accounts screen (approved prototype group 4, R-MGMT-1, R-ACC-1…5): accounts grouped with
/// their balances on the left, the inspector on the right; "New account" in the toolbar.
///
/// The shell routes `AppSection.accounts` here, keeping the model alive (`init(model:)`) or
/// letting the view own one (`init(dependencies:)`).
public struct AccountsView: View {
  @State private var model: AccountsModel
  /// The currency a new account starts with (the shell's display currency).
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
      ToolbarItem(placement: .primaryAction) {
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
    .task { if model.phase == .idle { await model.load() } }
  }
}

/// "Show archived accounts" and the grouped list (R-MGMT-1).
struct AccountsList: View {
  let model: AccountsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Toggle(
        "Show archived accounts",
        isOn: Binding(get: { model.showArchived }, set: { model.setShowArchived($0) })
      )
      .toggleStyle(.checkbox)
      .font(.system(size: 12))
      .padding(.horizontal, ManageMetrics.horizontalPadding)
      .padding(.vertical, 8)
      List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
        ForEach(model.groups) { group in
          Section {
            ForEach(group.rows) { row in
              AccountRowView(row: row).tag(row.id)
            }
          } header: {
            Text(group.name)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
    }
  }
}

/// Tile with the currency symbol (red for liabilities), name, "Kind · CUR", balance.
struct AccountRowView: View {
  let row: AccountRow

  var body: some View {
    HStack(spacing: 12) {
      Text(row.symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(row.isLiability ? ManagePalette.liability : ManagePalette.asset, in: .rect(cornerRadius: 8))
        .opacity(row.isArchived ? 0.45 : 1)
        .accessibilityHidden(true)
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
        Text(row.detail).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(row.balanceText)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(row.isNegative ? ManagePalette.negative : Color.primary)
    }
    .font(.system(size: 13))
    .padding(.vertical, 5)
    .accessibilityElement(children: .combine)
  }
}

/// Name, kind, currency (fixed after the first transaction), opening balance and date, group,
/// IBAN, current balance; Archive… / Unarchive and Delete… (R-ACC-1, R-ACC-4, R-ACC-5).
struct AccountInspectorView: View {
  let model: AccountsModel

  private func binding<Value>(_ keyPath: WritableKeyPath<AccountDraft, Value>, _ fallback: Value) -> Binding<Value> {
    draftBinding({ model.draft }, { model.draft = $0 }, keyPath, fallback: fallback)
  }

  var body: some View {
    if let draft = model.draft {
      ManageInspector(title: model.inspectorTitle) {
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
              ForEach(ManageText.liabilityKinds, id: \.self) { Text(ManageText.kindTitle($0)).tag($0) }
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
          TextField("Group", text: binding(\.group, ""), prompt: Text("e.g. Monobank, PKO"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
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
        ManageSaveBar(
          isNew: draft.isNew, isDirty: model.isDirty, canSave: model.canSave, validation: model.validationMessage,
          error: model.errorMessage, onRevert: model.revert
        ) {
          Task { await model.save() }
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
    } else {
      ManageInspector(title: "") {
        Text("Select an account or create one.").foregroundStyle(.secondary)
      }
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
