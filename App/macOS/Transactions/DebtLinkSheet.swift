import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The "Debt record" sheet (R-DEBT-10/11, docs/status/C17.md), shared by the import wizard and
/// "Convert to debt record…" in the transaction list: person (existing or a new name), debt,
/// kind, the expense/income flag where offered and, across currencies, the amount in the debt's
/// currency. Save bottom-right.
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
        Picker("Debt", selection: $draft.debt) {
          ForEach(draft.debtChoices) { choice in
            Text(choice.label).tag(choice.option)
          }
        }
        .disabled(draft.trimmedPerson.isEmpty)
        Picker("Kind", selection: $draft.kind) {
          ForEach(draft.kindOptions, id: \.self) { kind in
            Text(kind.title).tag(kind)
          }
        }
        if let flag = draft.flagTitle {
          Toggle(flag, isOn: $draft.countsInReports)
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
      Text("The transaction becomes the record's money on your account — it is not counted twice.")
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
