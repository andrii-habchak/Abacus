import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Categories screen (approved prototype group 4, R-MGMT-2, R-MGMT-8, R-CAT-1…3, D55): page
/// search, Expense / Income tabs and the sort selector, the built-in "Uncategorised" pinned on
/// top, the one-level tree in a native outline list (a line between rows reorders, a
/// highlighted row nests) with usage counts; the editor is a sheet (double-click / Return /
/// "Edit…"); only "New category" in the toolbar; Delete… asks where a used category's
/// transactions go.
public struct CategoriesView: View {
  @State private var model: CategoriesModel

  public init(model: CategoriesModel) {
    _model = State(initialValue: model)
  }

  public init(dependencies: ManageDependencies) {
    self.init(model: CategoriesModel(dependencies: dependencies))
  }

  public var body: some View {
    ManagePhaseView(phase: model.phase, title: "Categories", retry: { await model.load() }) {
      CategoriesTree(model: model)
        .frame(minWidth: 380, maxWidth: .infinity)
    }
    .navigationTitle("Categories")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("New category", systemImage: "plus") { model.newCategory() }
          .labelStyle(.titleAndIcon)
      }
    }
    .sheet(item: Binding(get: { model.sheet }, set: { if $0 == nil, model.sheet != nil { model.dismissSheet() } })) {
      draft in
      CategoryEditorSheet(model: model, initial: draft)
    }
    // Confirmations raised outside the editor; the editor sheet shows its own.
    .sheet(
      item: Binding(
        get: { model.sheet == nil ? model.dialog : nil },
        set: { if $0 == nil, model.sheet == nil, model.dialog != nil { model.cancelDialog() } })
    ) { dialog in
      CategoryDeleteDialog(model: model, dialog: dialog)
    }
    .sheet(
      item: Binding(
        get: { model.reassignSheet }, set: { if $0 == nil, model.reassignSheet != nil { model.cancelReassign() } })
    ) { sheet in
      CategoryReassignSheetView(model: model, initial: sheet)
    }
    .task {
      if model.phase == .idle { await model.load() }
      #if DEBUG
        for _ in 0..<50 where model.phase != .loaded || model.rows.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        openDebugSheet()
      #endif
    }
  }

  #if DEBUG
    /// UI checks (in-app snapshot): `-AbacusOpenSheet newCategory|editCategory|editUncategorised`
    /// opens that sheet once the page has loaded.
    private func openDebugSheet() {
      switch UserDefaults.standard.string(forKey: "AbacusOpenSheet") {
      case "newCategory": model.newCategory()
      case "editCategory": if let row = model.rows.first(where: { !$0.isChild }) { model.edit(row.id) }
      case "editUncategorised": model.edit(CategoriesModel.uncategorisedID)
      default: break
      }
    }
  #endif
}

/// "Re-assign…" (C33): moves every transaction of a category (and of its subcategories) to another
/// category of the same kind. Plain pickers for now; the shared searchable picker (C34) replaces
/// the target Picker later.
struct CategoryReassignSheetView: View {
  let model: CategoriesModel
  @State private var sheet: CategoryReassignSheet
  @State private var working = false

  init(model: CategoriesModel, initial: CategoryReassignSheet) {
    self.model = model
    _sheet = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Re-assign “\(sheet.sourceName)”").font(.system(size: 15, weight: .semibold))
      if sheet.targets.isEmpty {
        Text("There is no other active \(sheet.kind.rawValue) category to move them to.")
          .foregroundStyle(.secondary)
      } else {
        ManageField("Move to") {
          Picker("Move to", selection: $sheet.targetID) {
            ForEach(sheet.targets) { target in
              Text(target.isChild ? "    \(target.name)" : target.name).tag(Optional(target.id))
            }
          }
          .labelsHidden()
        }
      }
      Text(sheet.summary).fixedSize(horizontal: false, vertical: true)
      ForEach(sheet.notes, id: \.self) { note in
        Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Toggle(isOn: $sheet.repointRules) {
        Text(sheet.impact.rules + sheet.impact.importMappings > 0
          ? "Re-point rules that use this category (\(sheet.impact.rules + sheet.impact.importMappings))"
          : "Re-point rules that use this category")
      }
      Toggle("Archive “\(sheet.sourceName)” afterwards", isOn: $sheet.archiveAfterwards)
      if let message = sheet.errorMessage {
        Text(message).font(.system(size: 12)).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.cancelReassign() }
          .keyboardShortcut(.cancelAction)
        Button("Re-assign") {
          working = true
          Task {
            await model.confirmReassign(sheet)
            working = false
            // A failure stays on the model's sheet; show it here.
            sheet.errorMessage = model.reassignSheet?.errorMessage
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canConfirmReassign(sheet) || working)
      }
    }
    .padding(20)
    .frame(width: 440)
  }
}

/// The delete dialog with its reassignment target (R-CAT-3).
struct CategoryDeleteDialog: View {
  let model: CategoriesModel
  let dialog: ManageDialog

  var body: some View {
    ManageDialogView(
      dialog: dialog,
      target: Binding(get: { model.reassignTarget }, set: { model.reassignTarget = $0 }),
      canConfirm: model.canConfirmDialog,
      onArchiveInstead: { Task { await model.archiveInstead() } },
      onCancel: model.cancelDialog
    ) {
      Task { await model.confirmDialog() }
    }
  }
}

/// Search, kind tabs, sort, and the outline (R-MGMT-2, R-MGMT-8, R-MGMT-11, D55).
struct CategoriesTree: View {
  let model: CategoriesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PageSearchField(
        text: Binding(get: { model.searchText }, set: { model.searchText = $0 }), prompt: "Search categories")
        .padding(.horizontal, ManageMetrics.horizontalPadding)
        .padding(.top, 12)
      HStack(spacing: 12) {
        Picker("Kind", selection: Binding(get: { model.kind }, set: { model.setKind($0) })) {
          Text("Expense").tag(CategoryKind.expense)
          Text("Income").tag(CategoryKind.income)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer(minLength: 8)
        Picker("Sort", selection: Binding(get: { model.sort }, set: { sort in Task { await model.setSort(sort) } })) {
          ForEach(CategorySort.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Order of the list")
      }
      .padding(.horizontal, ManageMetrics.horizontalPadding)
      .padding(.top, 10)
      .padding(.bottom, 6)
      OutlineList(
        nodes: nodes,
        selection: model.selectedIDs,
        rowHeight: 30,
        onSelect: { model.select(ids: $0) },
        onActivate: { model.edit($0) },
        canDrop: { model.canDrop($0.moving, on: $0.target, position: $0.position) },
        onDrop: { drop in Task { await model.drop(drop.moving, on: drop.target, position: drop.position) } },
        menuItems: { id in
          var items = [OutlineMenuItem(title: "Show all transactions") { model.showTransactions(of: id) }]
          if model.canReassign(id) {
            items.append(OutlineMenuItem(title: "Re-assign…") { Task { await model.requestReassign(id) } })
          }
          return items
        }
      )
      .padding(.horizontal, 8)
      .overlay {
        if let message = model.emptySearchMessage {
          Text(message).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var nodes: [OutlineNode] {
    var nodes: [OutlineNode] = []
    if let row = model.uncategorisedRow {
      nodes.append(OutlineNode(id: row.id, signature: row, isPinned: true) { CategoryRowView(row: row) })
    }
    nodes += OutlineTree.nodes(model.rows, isChild: \.isChild) { row, children in
      OutlineNode(id: row.id, signature: row, children: children) { CategoryRowView(row: row) }
    }
    return nodes
  }
}

/// Drag handle, colour dot, name (parents bold; the outline indents children), usage count.
struct CategoryRowView: View {
  let row: CategoryRow

  var body: some View {
    HStack(spacing: 10) {
      if row.isBuiltIn {
        Image(systemName: "pin.fill")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .frame(width: 10)
      } else {
        ManageGrip()
      }
      ManageDot(hex: row.colorHex)
      HStack(spacing: 6) {
        Text(row.name)
          .fontWeight(row.isChild ? .regular : .semibold)
          .lineLimit(1)
        if row.isArchived {
          badge("Archived")
        }
        if row.isBuiltIn {
          badge("Built in")
        }
      }
      .opacity(row.isArchived || !row.matchesSearch ? 0.55 : 1)
      Spacer(minLength: 8)
      Text(row.usage).font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(.trailing, 8)
    }
    .font(.system(size: 13))
    .frame(maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func badge(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(ManagePalette.badge, in: .capsule)
  }
}

/// The category editor (D55, R-CAT-1…3): name, parent, colour, usage; Archive and Delete… on
/// the left, Cancel and Save on the right (R-MGMT-10). The built-in "Uncategorised" shows its
/// colour only (D47). The form is this sheet's own state; the model sees it on Save.
struct CategoryEditorSheet: View {
  let model: CategoriesModel
  @State private var draft: CategoryDraft
  /// The form as opened: the validation message waits for the first edit.
  private let initial: CategoryDraft

  init(model: CategoriesModel, initial: CategoryDraft) {
    self.model = model
    self.initial = initial
    _draft = State(initialValue: initial)
  }

  private var title: String {
    if draft.isNew { return draft.kind == .income ? "New income category" : "New expense category" }
    if draft.isBuiltIn { return Uncategorised.title }
    return model.category(draft.id)?.name ?? draft.name
  }

  var body: some View {
    ManageEditorSheet(
      title: title,
      message: draft != initial ? model.validationMessage(draft) : nil,
      error: model.errorMessage,
      saveTitle: draft.isNew ? "Create" : "Save",
      canSave: model.canSave(draft),
      width: 420,
      onCancel: model.dismissSheet,
      onSave: { Task { await model.save(draft) } }
    ) {
      ManageField("Name") {
        if draft.isBuiltIn {
          Text(Uncategorised.title)
            .foregroundStyle(.secondary)
            .help("The built-in entry can't be renamed")
        } else {
          TextField("Name", text: $draft.name)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
        }
      }
      if !draft.isBuiltIn {
        ManageField("Parent") {
          Picker("Parent", selection: $draft.parentID) {
            Text("None (top level)").tag(AbacusDomain.Category.ID?.none)
            ForEach(model.parentOptions(draft)) { Text($0.name).tag(Optional($0.id)) }
          }
          .labelsHidden()
          .disabled(!model.canChangeParent(draft))
          if !model.canChangeParent(draft) {
            Text("Has subcategories, so it stays at the top level.")
              .font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
      }
      ManageField("Colour") {
        ManageColorField(hex: $draft.colorHex)
      }
      if !draft.isNew {
        ManageCard {
          Text(model.usageText(draft)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    } actions: {
      if !draft.isNew, !draft.isBuiltIn, model.selection == draft.id {
        Button(model.archiveTitle) { Task { await model.archiveOrUnarchive() } }
        Button("Delete…", role: .destructive) { model.requestDelete() }
      }
    }
    .sheet(
      item: Binding(get: { model.dialog }, set: { if $0 == nil, model.dialog != nil { model.cancelDialog() } })
    ) { dialog in
      CategoryDeleteDialog(model: model, dialog: dialog)
    }
  }
}

#Preview("Categories · expense") {
  CategoriesView(dependencies: .preview())
    .frame(width: 1000, height: 720)
}

#Preview("Categories · income") {
  let model = CategoriesModel(dependencies: .preview())
  return CategoriesView(model: model)
    .task {
      await model.load()
      model.setKind(.income)
    }
    .frame(width: 1000, height: 720)
}
