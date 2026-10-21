import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Rules screen (approved prototype group 4, R-MGMT-6, R-IMP-8): the "Try a description"
/// tester, the rules in evaluation order (drag to reorder, enable toggles, origin, hit counts),
/// edit on double-click, delete; "New rule" in the toolbar.
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
    .navigationTitle("Categorisation rules")
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
    .task { if model.phase == .idle { await model.load() } }
  }
}

struct RulesContent: View {
  @Bindable var model: RulesModel

  static let columns: [ManageColumns.Column] = [.fixed(36), .flex(1.6), .flex(1.2), .flex(1.4), .flex(1.2), .fixed(52)]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ManageField("Try a description") {
        HStack(spacing: 8) {
          TextField("Try a description", text: $model.probe, prompt: Text("e.g. BIEDRONKA 1234 WARSZAWA"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 420)
          Picker("Account", selection: $model.probeAccountID) {
            Text("on any account").tag(Account.ID?.none)
            ForEach(model.accountOptions) { Text("on \($0.name)").tag(Optional($0.id)) }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      .font(.system(size: 13))
      if !model.probeResult.isEmpty {
        Text(model.probeResult)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(model.match != nil ? ManagePalette.matchText : Color.secondary)
      }

      VStack(spacing: 0) {
        ManageColumns(columns: Self.columns) {
          Text("On")
          Text("Description contains")
          Text("Account")
          Text("Category")
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
            .listRowBackground(row.isMatch ? ManagePalette.match : Color.clear)
            .contextMenu {
              Button("Edit…") { model.edit(row.id) }
              Button("Delete…", role: .destructive) { model.requestDelete(row.id) }
            }
          }
          .onMove { source, destination in
            Task { await model.move(fromOffsets: source, toOffset: destination) }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: CategoryRule.ID.self) { _ in
        } primaryAction: { ids in
          if let id = ids.first { model.edit(id) }
        }
        .overlay {
          if model.rows.isEmpty {
            Text("No rules yet. Choices you make during an import are saved here.")
              .foregroundStyle(.secondary)
          }
        }
      }
      .background(ManagePalette.card)
      .clipShape(.rect(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ManagePalette.border))

      HStack(spacing: 8) {
        Text("Rules are checked top to bottom; the first match wins. Choices you make during an import are saved here as rules.")
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
      Text(row.pattern)
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
      Text(row.account).foregroundStyle(.secondary).lineLimit(1)
      Text(row.category).lineLimit(1)
      Text(row.origin).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      Text("\(row.hits)").foregroundStyle(.secondary).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.system(size: 13))
    .foregroundStyle(row.isEnabled ? Color.primary : Color.secondary)
    .padding(.vertical, 4)
  }
}

/// New / edit rule: pattern, account (any or one), category (R-IMP-8).
struct RuleEditorSheet: View {
  let model: RulesModel

  private func binding<Value>(_ keyPath: WritableKeyPath<RuleDraft, Value>, _ fallback: Value) -> Binding<Value> {
    draftBinding({ model.editor }, { model.editor = $0 }, keyPath, fallback: fallback)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.editor?.isNew == true ? "New rule" : "Edit rule")
        .font(.system(size: 15, weight: .semibold))
      ManageField("Description contains") {
        TextField("Description contains", text: binding(\.pattern, ""), prompt: Text("e.g. biedronka"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
      ManageField("Account") {
        Picker("Account", selection: binding(\.accountID, nil)) {
          Text("Any account").tag(Account.ID?.none)
          ForEach(model.accountOptions) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
      }
      ManageField("Category") {
        Picker("Category", selection: binding(\.categoryID, nil)) {
          Text("Choose…").tag(AbacusDomain.Category.ID?.none)
          ForEach(model.categoryOptions) { category in
            Text(category.parentID == nil ? category.name : "    \(category.name)").tag(Optional(category.id))
          }
        }
        .labelsHidden()
      }
      if let message = model.editorValidation {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.cancelEditor() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { Task { await model.saveEditor() } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(model.editorValidation != nil)
      }
    }
    .font(.system(size: 13))
    .padding(20)
    .frame(width: 420)
  }
}

#Preview("Rules") {
  RulesView(model: RulesModel(dependencies: .preview(), probe: "BIEDRONKA 1234 WARSZAWA"))
    .frame(width: 1000, height: 600)
}
