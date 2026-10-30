import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The "Transfer to debt account" sheet (R-DEBT-10/11/19, docs/status/C22.md), shared by the
/// import wizard and "Transfer to Debt Account…" in the transaction list: person (existing,
/// completed as you type, or a new name), the person's account (a linked one, or a new virtual
/// account in a currency) and, across currencies, the amount on their side. Save bottom-right.
struct DebtLinkSheet: View {
  /// The draft as the owner keeps it; the sheet edits a local copy and hands it back on Save, so
  /// the owner clearing its draft while the sheet closes never leaves a dangling binding (D54).
  let initial: DebtLinkDraft
  var saveTitle: String = "Save"
  var onCancel: () -> Void
  var onSave: (DebtLinkDraft) -> Void

  @State private var draft: DebtLinkDraft

  init(
    initial: DebtLinkDraft, saveTitle: String = "Save", onCancel: @escaping () -> Void,
    onSave: @escaping (DebtLinkDraft) -> Void
  ) {
    self.initial = initial
    self.saveTitle = saveTitle
    self.onCancel = onCancel
    self.onSave = onSave
    _draft = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(draft.title).font(.headline).lineLimit(2)
        Text(draft.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Form {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            TextField("Person", text: $draft.personName, prompt: Text("Name"))
            if !draft.personOptions.isEmpty {
              Menu {
                ForEach(draft.personOptions, id: \.self) { name in
                  Button(name) { draft.personName = name }
                }
              } label: {
                Image(systemName: "person.crop.circle")
              }
              .menuStyle(.borderlessButton)
              .fixedSize()
              .help("People with debts")
            }
          }
          if draft.createsDebt {
            Text("New debt").font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
        Picker("Account", selection: $draft.account) {
          ForEach(draft.accountChoices) { choice in
            Text(choice.label).tag(choice.option)
          }
        }
        .disabled(draft.trimmedPerson.isEmpty)
        if draft.choosesCurrency {
          Picker("Currency", selection: $draft.newAccountCurrency) {
            ForEach(Currency.allCases, id: \.self) { currency in
              Text(currency.rawValue).tag(currency)
            }
          }
          .disabled(draft.trimmedPerson.isEmpty)
        }
        if draft.needsAmount {
          TextField(draft.amountCaption, text: $draft.amountText, prompt: Text("0.00"))
            .monospacedDigit()
        }
      }
      .formStyle(.columns)
      if let validation = draft.validation, !draft.trimmedPerson.isEmpty || draft.needsAmount {
        Text(validation).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Text("The transaction becomes a transfer between your account and the person's — it is not counted twice.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button(saveTitle) { onSave(draft) }
          .keyboardShortcut(.defaultAction)
          .disabled(!draft.canSave)
      }
    }
    .padding(20)
    .frame(width: 440)
  }
}
