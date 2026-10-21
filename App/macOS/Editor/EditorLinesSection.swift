import AbacusDomain
import AbacusFeatures
import SwiftUI

/// "Fees, cashback and split lines" (R-EDIT-2, R-TX-6): Add fee / Add line, one row per line
/// (Expense | Income, category, amount, note, remove), and "Effect on <account>".
struct EditorLinesSection: View {
  @Bindable var model: TransactionEditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Fees, cashback and split lines")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(EditorPalette.label)
        Spacer(minLength: 0)
        Button("Add fee") { model.addFee() }
          .buttonStyle(EditorFooterButtonStyle())
          .font(.system(size: 12))
        Button("Add line") { model.addLine() }
          .buttonStyle(EditorFooterButtonStyle())
          .font(.system(size: 12))
      }
      if model.lines.isEmpty {
        Text("None. A fee is charged to the same account and counted under its own category.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      ForEach($model.lines) { $line in
        EditorLineRow(model: model, line: $line)
      }
      HStack(spacing: 8) {
        Text(model.effectLabel)
          .foregroundStyle(EditorPalette.label)
        Spacer(minLength: 0)
        Text(model.effectText)
          .fontWeight(.semibold)
          .monospacedDigit()
      }
      .font(.system(size: 12))
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(RoundedRectangle(cornerRadius: 8).fill(EditorPalette.summary))
    }
    .padding(.top, 12)
    .padding(.bottom, 4)
  }
}

struct EditorLineRow: View {
  let model: TransactionEditorModel
  @Binding var line: EditorLine

  var body: some View {
    let options = model.lineCategoryOptions(line)
    HStack(spacing: 6) {
      Picker(
        "Line kind",
        selection: Binding(get: { line.kind }, set: { model.setLineKind(line.id, $0) })
      ) {
        Text("Expense").tag(CategoryKind.expense)
        Text("Income").tag(CategoryKind.income)
      }
      .labelsHidden()
      .frame(width: 96, alignment: .leading)
      Picker("Line category", selection: $line.categoryID) {
        if line.categoryID == nil {
          Text("Category").tag(AbacusDomain.Category.ID?.none)
        }
        ForEach(options.primary) { option in
          Text(option.isChild ? "\u{2003}" + option.name : option.name).tag(Optional(option.id))
        }
        if !options.refund.isEmpty {
          Section("Refund to an expense category") {
            ForEach(options.refund) { option in
              Text(option.isChild ? "\u{2003}" + option.name : option.name).tag(Optional(option.id))
            }
          }
        }
      }
      .labelsHidden()
      .frame(width: 150, alignment: .leading)
      EditorAmountField(title: "Line amount", text: $line.amountText, width: 80)
      TextField("Line note", text: $line.note, prompt: Text("Note"))
        .labelsHidden()
        .frame(minWidth: 80, maxWidth: .infinity)
      Button {
        model.removeLine(line.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Remove line")
    }
    .controlSize(.small)
    .padding(6)
    .background(RoundedRectangle(cornerRadius: 8).fill(EditorPalette.lineBackground))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(EditorPalette.rule))
  }
}
