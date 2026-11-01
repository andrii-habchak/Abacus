import AbacusDomain
import AbacusFeatures
import AbacusImport
import SwiftUI

/// C40: the transfer popup of the import review, opened by double-clicking a transfer row. From and
/// To (searchable account pickers), what the transfer is related to with "Change transaction…",
/// and under each account the transactions of that account on the transfer's day.
struct ImportTransferSheet: View {
  let model: ImportWizardModel
  @Bindable var editor: ImportTransferEditor

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(editor.title).font(.headline).lineLimit(1)
        Text(editor.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      related
      HStack(alignment: .top, spacing: 12) {
        side(
          title: "From", note: editor.fromNote, items: editor.fromItems, selection: $editor.fromAccountID,
          other: editor.toAccountID, lines: editor.fromLines)
        Image(systemName: "arrow.right")
          .foregroundStyle(.secondary)
          .padding(.top, 30)
        side(
          title: "To", note: editor.toNote, items: editor.toItems, selection: $editor.toAccountID,
          other: editor.fromAccountID, lines: editor.toLines)
      }
      .frame(maxHeight: .infinity)
      if let error = editor.errorMessage {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Text("Double-click a transfer row to open this again.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { model.cancelTransferEditor() }.keyboardShortcut(.cancelAction)
        Button(editor.hasChanges ? "Save" : "Done") { model.saveTransferEditor() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(20)
    .frame(width: 700, height: 620)
    .task(id: editor.listKey) { await editor.load() }
    .sheet(
      isPresented: Binding(
        get: { model.counterpartPicker != nil },
        set: { if !$0 { model.cancelCounterpart() } })
    ) {
      if let picker = model.counterpartPicker {
        ImportCounterpartSheet(model: model, picker: picker.model)
      }
    }
  }

  /// What made the row a transfer and the transaction of the other account it is tied to.
  private var related: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Related to").font(.system(size: 12, weight: .semibold))
      ForEach(editor.relations, id: \.self) { text in
        Label(text, systemImage: "link")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Text(editor.relatedTransaction)
          .font(.system(size: 12))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .help(editor.relatedTransaction)
        Spacer(minLength: 8)
        Button("Change transaction…") { model.changeTransferTransaction() }
          .disabled(!editor.canChangeTransaction || editor.hasChanges)
          .help(
            editor.hasChanges
              ? "Save the account change first"
              : "Find the other side of this transfer among the transactions of \(editor.dayText)")
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(ImportPalette.surface))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ImportPalette.border))
  }

  private func side(
    title: String, note: String, items: [AccountPickerItem], selection: Binding<Account.ID?>, other: Account.ID?,
    lines: [ImportTransferEditor.Line]
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 12, weight: .semibold))
      AccountPicker(
        items: items, selection: selection, excluding: other.map { [$0] } ?? [], placeholder: "Choose account…",
        width: .infinity, accessibilityTitle: title)
      Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
      Text("Transactions on \(editor.dayText)")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
      if lines.isEmpty {
        Text(editor.isLoading ? "Loading…" : "None.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        List(lines) { line in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(line.title).lineLimit(1)
              HStack(spacing: 4) {
                Text(line.subtitle)
                if let badge = line.badge {
                  Text(badge)
                    .fontWeight(.semibold)
                    .foregroundStyle(ImportPalette.accentText)
                }
              }
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(line.amountText)
              .monospacedDigit()
              .foregroundStyle(line.isInflow ? ImportPalette.inflow : .primary)
          }
          .font(.system(size: 12))
        }
        .listStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
