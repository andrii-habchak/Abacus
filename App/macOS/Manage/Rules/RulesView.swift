import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Rules screen (approved prototype group 4, R-MGMT-6, R-IMP-8, D44, D56): page search and
/// the category filter, the rules in evaluation order and in words (drag to reorder, enable
/// toggles, origin, hit counts), the Saldo-like editor on double-click, delete; "New rule" in
/// the toolbar.
public struct RulesView: View {
  @State private var model: RulesModel

  public init(model: RulesModel) {
    _model = State(initialValue: model)
  }

  public init(dependencies: ManageDependencies) {
    self.init(model: RulesModel(dependencies: dependencies))
  }

  public var body: some View {
    ManagePhaseView(phase: model.phase, title: "Rules", retry: { await model.load() }) {
      RulesContent(model: model)
    }
    .navigationTitle("Rules")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("New rule", systemImage: "plus") { model.newRule() }
          .labelStyle(.titleAndIcon)
      }
    }
    .sheet(item: Binding(get: { model.dialog }, set: { if $0 == nil { model.cancelDialog() } })) { dialog in
      ManageDialogView(dialog: dialog, onCancel: model.cancelDialog) {
        Task { await model.confirmDialog() }
      }
    }
    .sheet(isPresented: Binding(get: { model.editor != nil }, set: { if !$0 { model.cancelEditor() } })) {
      RuleEditorSheet(model: model)
    }
    .task {
      if model.phase == .idle { await model.load() }
      #if DEBUG
        openEditorForSnapshot()
      #endif
    }
    #if DEBUG
      // Sample data may arrive after the first load.
      .onChange(of: model.rules.count) { openEditorForSnapshot() }
    #endif
  }

  #if DEBUG
    /// Debug builds: `-AbacusRuleEditor new|<pattern>` opens the editor on launch (UI snapshots),
    /// `-AbacusRuleEditorApply YES` ticks "Update existing transactions".
    @MainActor private static var openedForSnapshot = false

    private func openEditorForSnapshot() {
      let defaults = UserDefaults.standard
      // `-AbacusRuleDemoApply <text>`: a new rule "<text> → first expense category A–Z" saved
      // and applied to existing transactions through the editor's path (Save & apply →
      // confirmation → apply), then opened again (the banner and "Roll back…").
      if !Self.openedForSnapshot, model.editor == nil, !model.rules.isEmpty,
        let text = defaults.string(forKey: "AbacusRuleDemoApply")
      {
        Self.openedForSnapshot = true
        Task {
          model.newRule()
          model.editor?.pattern = text
          model.editor?.categoryID = model.categoryOptions.first { $0.kind == .expense }?.id
          model.editor?.updateExisting = true
          await model.loadEditorTransactions()
          await model.saveEditor()
          if let pending = model.confirmation {
            model.cancelConfirmation()  // what the alert's binding does before the button's Task
            await model.confirmApply(pending)
          }
          if let rule = model.rules.first(where: { $0.pattern == text }) { model.edit(rule.id) }
        }
        return
      }
      guard !Self.openedForSnapshot, model.editor == nil, let target = defaults.string(forKey: "AbacusRuleEditor") else { return }
      if target != "new", !model.rules.contains(where: { $0.pattern == target }) { return }
      Self.openedForSnapshot = true
      if target == "new" {
        model.newRule()
      } else if let rule = model.rules.first(where: { $0.pattern == target }) {
        model.edit(rule.id)
      }
      if defaults.bool(forKey: "AbacusRuleEditorApply") { model.editor?.updateExisting = true }
    }
  #endif
}

struct RulesContent: View {
  @Bindable var model: RulesModel

  static let columns: [ManageColumns.Column] = [.fixed(36), .flex(2.6), .flex(1.5), .flex(1.1), .fixed(52)]

  /// "All categories" / "Food › Groceries".
  private var categoryFilterTitle: String {
    guard let id = model.categoryFilter, let category = model.categories.first(where: { $0.id == id }) else {
      return "All categories"
    }
    guard let parent = category.parentID.flatMap({ pid in model.categories.first { $0.id == pid } }) else {
      return category.name
    }
    return "\(parent.name) › \(category.name)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      // R-MGMT-11: page search, then the category filter, both full width.
      PageSearchField(text: $model.searchText, prompt: "Search rules")
      // A menu with a full-width label (a menu picker keeps its own width on macOS).
      Menu {
        Picker("Category", selection: $model.categoryFilter) {
          Text("All categories").tag(AbacusDomain.Category.ID?.none)
          Divider()
          ForEach(model.categoryFilterOptions) { category in
            Text(category.parentID == nil ? category.name : "    \(category.name)").tag(Optional(category.id))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "line.3.horizontal.decrease.circle")
            .foregroundStyle(.secondary)
          Text(categoryFilterTitle)
          Spacer(minLength: 0)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .frame(maxWidth: .infinity)
      .accessibilityLabel("Filter rules by category")

      if let notice = model.notice {
        HStack(spacing: 10) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(ManagePalette.matchText)
          Text(notice.message)
          Spacer(minLength: 0)
          if let ruleID = notice.rollbackRuleID {
            Button("Roll back") { Task { await model.rollBack(ruleID) } }
          }
          Button("Dismiss", systemImage: "xmark") { model.dismissNotice() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ManagePalette.match, in: .rect(cornerRadius: 8))
      }

      VStack(spacing: 0) {
        ManageColumns(columns: Self.columns) {
          Text("On")
          Text("When")
          Text("Then")
          Text("Origin")
          Text("Used").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(ManagePalette.headerBackground)
        Divider()
        List(selection: $model.selection) {
          ForEach(model.rows) { row in
            RuleRowView(row: row, columns: Self.columns) { enabled in
              Task { await model.setEnabled(row.id, enabled) }
            }
            .tag(row.id)
            .contextMenu {
              Button("Edit…") { model.edit(row.id) }
              Button("Delete…", role: .destructive) { model.requestDelete(row.id) }
            }
          }
          // Dragging reorders the full list, so it is off while the search or filter hides rules.
          .onMove(
            perform: model.isFiltered
              ? nil
              : { source, destination in Task { await model.move(fromOffsets: source, toOffset: destination) } })
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: CategoryRule.ID.self) { _ in
        } primaryAction: { ids in
          if let id = ids.first { model.edit(id) }
        }
        .overlay {
          if model.rows.isEmpty {
            Text(model.emptyText)
              .foregroundStyle(.secondary)
          }
        }
      }
      .background(ManagePalette.card)
      .clipShape(.rect(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ManagePalette.border))

      HStack(spacing: 8) {
        Text(model.isFiltered
          ? "Rules are checked top to bottom; the first match wins. Clear the search and the category filter to drag rules into another order."
          : "Rules are checked top to bottom; the first match wins. Drag to reorder. Choices you make during an import are saved here as rules.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Edit…") { if let id = model.selection { model.edit(id) } }
          .disabled(model.selection == nil)
        Button("Delete…", role: .destructive) { if let id = model.selection { model.requestDelete(id) } }
          .disabled(model.selection == nil)
      }
      if let error = model.errorMessage {
        Text(error).font(.callout).foregroundStyle(ManagePalette.negative)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }
}

struct RuleRowView: View {
  let row: RuleRow
  let columns: [ManageColumns.Column]
  let onToggle: (Bool) -> Void

  var body: some View {
    ManageColumns(columns: columns) {
      Toggle("Enable rule \(row.pattern)", isOn: Binding(get: { row.isEnabled }, set: onToggle))
        .toggleStyle(.checkbox)
        .labelsHidden()
      Text(row.condition).lineLimit(2)
      HStack(spacing: 4) {
        Image(systemName: row.action.hasPrefix("Transfer") ? "arrow.left.arrow.right" : "tag")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Text(row.action).lineLimit(2)
      }
      Text(row.origin).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      Text("\(row.hits)").foregroundStyle(.secondary).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.system(size: 13))
    .foregroundStyle(row.isEnabled ? Color.primary : Color.secondary)
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.summary)
  }
}

/// New / edit rule, laid out like Saldo's editor (D44): a Condition card (description condition,
/// "+ Add AND condition" for amount and account), an Action card (assign category or transfer),
/// "Update existing transactions" and "Save & apply"; Delete in the header.
struct RuleEditorSheet: View {
  @Bindable var model: RulesModel
  @State private var confirmsDelete = false

  private func binding<Value>(_ keyPath: WritableKeyPath<RuleDraft, Value>, _ fallback: Value) -> Binding<Value> {
    draftBinding({ model.editor }, { model.editor = $0 }, keyPath, fallback: fallback)
  }

  private var draft: RuleDraft { model.editor ?? RuleDraft() }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(draft.isNew ? "New rule" : "Edit rule")
          .font(.system(size: 15, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        if !draft.isNew {
          Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderless)
            .foregroundStyle(ManagePalette.destructive)
            .focusable(false)
        }
      }

      section("Condition", "Which transactions should be affected?") { conditions }
      section("Action", "What should happen to these transactions?") { action }

      VStack(alignment: .leading, spacing: 4) {
        Toggle("Update existing transactions", isOn: binding(\.updateExisting, false))
          .toggleStyle(.checkbox)
        Text(updateCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 20)
      }
      rollback
      if let message = model.editorValidation {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.cancelEditor() }
          .keyboardShortcut(.cancelAction)
        Button(draft.updateExisting ? "Save & apply" : "Save") { Task { await model.saveEditor() } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(model.editorValidation != nil)
      }
    }
    .font(.system(size: 13))
    .padding(20)
    .frame(width: 540)
    .alert(
      model.confirmation?.title ?? "",
      isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelConfirmation() } })
    ) {
      // The confirmation is captured when the alert is built: tapping a button first clears the
      // alert's binding (→ cancelConfirmation()), and only then would a Task read the model —
      // reading `model.confirmation` there found nil and "Save & apply" did nothing (C9).
      let pending = model.confirmation
      Button("Cancel", role: .cancel) { model.cancelConfirmation() }
      Button("Save & apply") {
        if let pending { Task { await model.confirmApply(pending) } }
      }
    } message: {
      Text(model.confirmation?.message ?? "")
    }
    .alert("Delete this rule?", isPresented: $confirmsDelete) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) { Task { await model.deleteEditorRule() } }
    } message: {
      Text("It no longer applies to new transactions. Transactions it changed stay as they are.")
    }
  }

  private var updateCaption: String {
    guard draft.updateExisting else { return "Only new imports and new transactions use the rule." }
    return model.editorChangesText ?? (model.editorValidation == nil ? "Counting matching transactions…" : "Complete the rule to see how many change.")
  }

  private func section<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
    ManageCard {
      Text(title).font(.system(size: 13, weight: .semibold))
      Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
      content()
    }
  }

  // MARK: Condition

  /// TA v1.6: the first row is a description or an amount condition (its picker switches between
  /// them while it is the only one); "Add AND condition" adds the other kind and the account.
  @ViewBuilder private var conditions: some View {
    if draft.hasDescriptionCondition {
      conditionRow(isFirst: true, remove: draft.canRemoveDescription ? { model.removeDescriptionCondition() } : nil) {
        firstConditionPicker
        TextField("Text", text: binding(\.pattern, ""), prompt: Text("e.g. biedronka"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
    }
    if draft.hasAmountCondition {
      conditionRow(
        isFirst: !draft.hasDescriptionCondition, remove: draft.canRemoveAmount ? { model.removeAmountCondition() } : nil
      ) {
        if draft.hasDescriptionCondition {
          Picker("Amount", selection: binding(\.amountComparison, .biggerThan)) {
            Text("Amount is bigger than").tag(RuleAmountComparison.biggerThan)
            Text("Amount is smaller than").tag(RuleAmountComparison.smallerThan)
          }
          .labelsHidden()
          .fixedSize()
        } else {
          firstConditionPicker
        }
        TextField("Amount", text: binding(\.amountText, ""), prompt: Text("0.00"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(width: 110)
        Text("in the account's currency").font(.caption).foregroundStyle(.secondary)
      }
    }
    if draft.hasAccountCondition {
      conditionRow(isFirst: false, remove: { model.removeAccountCondition() }) {
        Text("Account is")
        Picker("Account", selection: binding(\.accountID, nil)) {
          Text("Choose…").tag(Account.ID?.none)
          AccountPickerItems(sections: model.accountSections) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
        .fixedSize()
      }
    }
    if draft.canAddCondition {
      Menu("Add AND condition", systemImage: "plus") {
        if !draft.hasDescriptionCondition {
          Button("Description contains or matches…") { model.addDescriptionCondition() }
        }
        if !draft.hasAmountCondition {
          Button("Amount is bigger or smaller than…") { model.addAmountCondition() }
        }
        if !draft.hasAccountCondition {
          Button("Only on account…") { model.addAccountCondition() }
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .foregroundStyle(ManagePalette.link)
    }
  }

  private var firstConditionPicker: some View {
    Picker("Condition", selection: binding(\.firstCondition, .descriptionContains)) {
      ForEach(draft.firstConditionChoices, id: \.self) { choice in
        Text(Self.title(choice)).tag(choice)
      }
    }
    .labelsHidden()
    .fixedSize()
  }

  private static func title(_ choice: RuleFirstCondition) -> String {
    switch choice {
    case .descriptionContains: "Description contains"
    case .descriptionExactly: "Description exactly matches"
    case .amountBiggerThan: "Amount is bigger than"
    case .amountSmallerThan: "Amount is smaller than"
    }
  }

  /// A condition row: "AND" before every row but the first, a remove button when the rule keeps
  /// a description or amount condition without it.
  private func conditionRow<Content: View>(
    isFirst: Bool, remove: (() -> Void)?, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 8) {
      if !isFirst {
        Text("AND")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(ManagePalette.badge, in: .rect(cornerRadius: 4))
      }
      content()
      if let remove {
        Spacer(minLength: 0)
        Button("Remove condition", systemImage: "xmark.circle.fill", action: remove)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Roll back

  /// TA v1.6: what the rule changed on existing transactions, with "Roll back…".
  @ViewBuilder private var rollback: some View {
    if !draft.isNew, let text = model.editorRollbackText {
      HStack(spacing: 8) {
        Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
        Text(text).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button("Roll back…") { model.requestRollback() }
      }
      .font(.system(size: 12))
      .alert(
        model.rollbackConfirmation?.title ?? "",
        isPresented: Binding(get: { model.rollbackConfirmation != nil }, set: { if !$0 { model.cancelRollback() } })
      ) {
        // Capture before the Task: the alert clears its binding first (see confirmApply).
        let pending = model.rollbackConfirmation
        Button("Cancel", role: .cancel) { model.cancelRollback() }
        Button("Roll back", role: .destructive) {
          if let pending { Task { await model.rollBack(pending.ruleID) } }
        }
      } message: {
        Text(model.rollbackConfirmation?.message ?? "")
      }
    }
  }

  // MARK: Action

  @ViewBuilder private var action: some View {
    HStack(spacing: 8) {
      Picker("Action", selection: binding(\.action, .category)) {
        Text("Assign category").tag(RuleAction.category)
        Text("Transfer to/from account").tag(RuleAction.transfer)
      }
      .labelsHidden()
      .fixedSize()
      switch draft.action {
      case .category:
        Picker("Category", selection: binding(\.categoryID, nil)) {
          Text("Choose…").tag(AbacusDomain.Category.ID?.none)
          ForEach(model.categoryOptions) { category in
            Text(category.parentID == nil ? category.name : "    \(category.name)").tag(Optional(category.id))
          }
        }
        .labelsHidden()
      case .transfer:
        Picker("Account", selection: binding(\.transferAccountID, nil)) {
          Text("Choose…").tag(Account.ID?.none)
          AccountPickerItems(sections: model.accountSections) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
      }
    }
    if draft.action == .transfer {
      Text("The transaction stays on its account and becomes a transfer: money out goes to this account, money in comes from it. Existing transfers are never changed.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

#Preview("Rules") {
  RulesView(dependencies: .preview())
    .frame(width: 1000, height: 600)
}
