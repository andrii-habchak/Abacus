import AbacusDomain
import AbacusFeatures
import AbacusImport
import AppKit
import SwiftUI

// C31: the bulk bar above the row lists, the "Save rules" sheet and the "New category" sheet.

/// Click on a row or card: plain = this one, Cmd = toggle, Shift = range (Accounts/Categories manner).
@MainActor
func importSelect(_ model: ImportWizardModel, _ id: String) {
  // The modifiers of the click being handled, else the keyboard state right now.
  let flags = (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
  if flags.contains(.shift) {
    model.select(id, mode: .range)
  } else if flags.contains(.command) {
    model.select(id, mode: .toggle)
  } else {
    model.select(id, mode: .replace)
  }
}

/// Acts on the selected rows: Category, Account, Debt, Skip. Shown above the rows of
/// Transactions and Needs review.
struct ImportBulkBar: View {
  let model: ImportWizardModel

  var body: some View {
    let info = model.bulk
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        if info.selected == 0 {
          Text(hint)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
          if model.hasSelectableRows {
            Button("Select all") { model.selectAll() }
              .buttonStyle(.link)
              .font(.system(size: 12))
          }
        } else {
          Text("\(info.selected.formatted()) selected")
            .font(.system(size: 12, weight: .semibold))
          categoryMenus(info)
          accountMenu(info)
          Button("Debt…") { Task { await model.openBulkDebt() } }
            .disabled(info.debtRows == 0)
            .help(info.debtRows == 0 ? "None of the selected rows can be recorded as a debt." : "Make the selected rows transfers to a debt account")
          Button("Skip") { model.bulkSkip() }
            .disabled(info.skipRows == 0)
            .help("Leave the selected rows out of the import")
          if info.includeRows > 0 {
            Button("Include") { model.bulkInclude() }
              .help("Bring skipped rows back")
          }
          Spacer(minLength: 8)
          Button("Clear") { model.clearSelection() }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
        if info.selected == 0 { Spacer(minLength: 0) }
      }
      .controlSize(.small)
      .padding(.horizontal, ImportMetrics.horizontalPadding)
      .padding(.vertical, 7)
      .frame(minHeight: 34)
      if let message = model.bulkMessage {
        HStack(spacing: 8) {
          Text(message)
            .font(.system(size: 12))
            .foregroundStyle(ImportPalette.accentText)
          if model.canUndoBulk {
            Button("Undo") { model.undoBulk() }
              .buttonStyle(.link)
              .font(.system(size: 12))
          }
          Spacer()
        }
        .padding(.horizontal, ImportMetrics.horizontalPadding)
        .padding(.bottom, 6)
      }
      ImportRule(color: ImportPalette.softRule)
    }
    .background(ImportPalette.bar)
  }

  private var hint: String {
    "Click a row to select it. Cmd+click adds a row, Shift+click selects a range."
  }

  @ViewBuilder
  private func categoryMenus(_ info: ImportBulkInfo) -> some View {
    if info.categoryKinds.isEmpty {
      Menu("Category") {}
        .disabled(true)
        .fixedSize()
        .help("None of the selected rows takes a category.")
    } else {
      let mixed = info.isMixedKinds
      ForEach(info.categoryKinds, id: \.self) { kind in
        HStack(spacing: 4) {
          // C36: the shared searchable picker; a pick applies at once to the rows of this kind.
          CategoryPicker(
            items: model.bulkCategoryPickerItems(kind),
            selection: Binding<AbacusDomain.Category.ID?>(
              get: { nil },
              set: { if let id = $0 { model.bulkSetCategory(id, kind: kind) } }),
            placeholder: mixed ? (kind == .expense ? "Expense category" : "Income category") : "Category"
          )
          .help(
            mixed
              ? "The selection mixes expenses and income: each picker sets only the \(kind == .expense ? "expense" : "income") rows."
              : "Set the category of the selected rows")
          Button("+ New…") { model.beginNewCategoryForSelection(kind: kind) }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .help("Create a \(kind == .expense ? "expense" : "income") category and set it on the selected rows")
        }
        .fixedSize()
      }
    }
  }

  private func accountMenu(_ info: ImportBulkInfo) -> some View {
    AccountPicker(
      sections: model.bulkAccountSections,
      selection: Binding(get: { nil }, set: { if let id = $0 { model.bulkSetTransfer(to: id) } }),
      fixedTitle: "Account"
    )
    .disabled(info.accountRows == 0)
    .help(info.accountRows == 0 ? "None of the selected rows can be a transfer." : "Make the selected rows transfers to one of your accounts")
  }
}

// MARK: - Rule suggestions

/// One suggested rule per pattern of the bulk selection: tick, edit the text, Save.
struct ImportRuleSheet: View {
  let model: ImportWizardModel
  @State private var sheet: RuleSuggestionSheet

  init(model: ImportWizardModel, initial: RuleSuggestionSheet) {
    self.model = model
    _sheet = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Save these as rules?")
        .font(.system(size: 15, weight: .semibold))
      Text(
        "Rules categorise the same payees automatically in later imports. Untick the ones you don't want, or change the text a rule looks for."
      )
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(spacing: 8) {
          ForEach($sheet.suggestions) { $suggestion in
            HStack(alignment: .top, spacing: 10) {
              Toggle("", isOn: $suggestion.isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
              VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                  TextField("Text", text: $suggestion.pattern)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!suggestion.isOn)
                  Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                  Text(suggestion.categoryName).lineLimit(1).fixedSize()
                }
                Text(
                  "\(rowsText(suggestion.rowCount)) · e.g. “\(suggestion.example)”"
                    + (suggestion.isOn && !suggestion.isValid ? " · needs at least 3 characters" : "")
                )
                .font(.system(size: 11))
                .foregroundStyle(suggestion.isOn && !suggestion.isValid ? ImportPalette.attention : .secondary)
                .lineLimit(1)
              }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(ImportPalette.border))
          }
        }
      }
      .frame(maxHeight: 320)
      HStack {
        Button("Not now") { model.dismissRuleSheet() }
          .keyboardShortcut(.cancelAction)
          .help("Keep the default: every pick is saved as a rule")
        Spacer()
        Button("Save rules") {
          model.ruleSheet = sheet
          model.applyRuleSheet()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!sheet.canConfirm)
      }
    }
    .font(.system(size: 13))
    .padding(20)
    .frame(width: 560)
  }
}

private func rowsText(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "row" : "rows")" }

// MARK: - New category

/// Name, kind (from the row) and optional parent; creates the category and picks it.
struct ImportNewCategorySheet: View {
  let model: ImportWizardModel
  @State private var draft: NewCategoryDraft

  init(model: ImportWizardModel, initial: NewCategoryDraft) {
    self.model = model
    _draft = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New \(draft.kind == .expense ? "expense" : "income") category")
        .font(.system(size: 15, weight: .semibold))
      TextField("Name", text: $draft.name)
        .textFieldStyle(.roundedBorder)
        .onSubmit { save() }
      Picker("Parent", selection: $draft.parentID) {
        Text("None (top level)").tag(AbacusDomain.Category.ID?.none)
        ForEach(model.newCategoryParents(draft.kind)) { parent in
          Text(parent.name).tag(AbacusDomain.Category.ID?.some(parent.id))
        }
      }
      HStack {
        Button("Cancel") { model.cancelNewCategory() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Create and select") { save() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!draft.isValid)
      }
    }
    .font(.system(size: 13))
    .padding(20)
    .frame(width: 380)
  }

  private func save() {
    guard draft.isValid else { return }
    let draft = draft
    Task { await model.saveNewCategory(draft) }
  }
}
