import AbacusDomain
import AbacusFeatures
import SwiftUI
import UniformTypeIdentifiers

/// The Categories screen (approved prototype group 4, R-MGMT-2, R-MGMT-8, R-CAT-1…3): page
/// search, Expense / Income tabs and the sort selector, the built-in "Uncategorised" pinned on
/// top, the one-level tree with drag and drop (between rows reorders, onto a row nests, like
/// Reminders) and usage counts, the inspector; only "New category" in the toolbar; Delete… asks
/// where a used category's transactions go.
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
      HStack(spacing: 0) {
        CategoriesTree(model: model)
          .frame(minWidth: 380, maxWidth: .infinity)
        Divider()
        CategoryInspectorView(model: model)
      }
    }
    .navigationTitle("Categories")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("New category", systemImage: "plus") { model.newCategory() }
          .labelStyle(.titleAndIcon)
      }
    }
    .sheet(item: Binding(get: { model.dialog }, set: { if $0 == nil { model.cancelDialog() } })) { dialog in
      CategoryDeleteDialog(model: model, dialog: dialog)
    }
    .task { if model.phase == .idle { await model.load() } }
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

/// Where a drag would land, for the drop indicator.
struct CategoryDropTarget: Equatable {
  /// nil: the space below the last row (top level, last).
  var id: AbacusDomain.Category.ID?
  var position: CategoryDropPosition
}

/// Search, kind tabs, sort, and the tree with drag and drop (R-MGMT-2, R-MGMT-8, R-MGMT-11).
struct CategoriesTree: View {
  let model: CategoriesModel
  @State private var dragging: AbacusDomain.Category.ID?
  @State private var dropTarget: CategoryDropTarget?

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
      List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
        if let row = model.uncategorisedRow {
          CategoryRowView(row: row, indicator: nil).tag(row.id)
        }
        ForEach(model.rows) { row in
          CategoryRowView(row: row, indicator: dropTarget?.id == row.id ? dropTarget?.position : nil)
            .tag(row.id)
            .onDrag {
              dragging = row.id
              return NSItemProvider(object: row.id.uuidString as NSString)
            }
            .onDrop(
              of: [.text],
              delegate: CategoryDropDelegate(
                model: model, target: row.id, dragging: $dragging, dropTarget: $dropTarget))
        }
        // Below the last row: top level, last.
        Color.clear
          .frame(height: 44)
          .overlay(alignment: .top) {
            if dropTarget == CategoryDropTarget(id: nil, position: .after) {
              Rectangle().fill(Color.accentColor).frame(height: 2)
            }
          }
          .listRowSeparator(.hidden)
          .onDrop(
            of: [.text],
            delegate: CategoryDropDelegate(model: model, target: nil, dragging: $dragging, dropTarget: $dropTarget))
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
      .overlay {
        if let message = model.emptySearchMessage {
          Text(message).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Between rows (the top or bottom quarter of a row) reorders, the middle nests (R-MGMT-8).
struct CategoryDropDelegate: DropDelegate {
  let model: CategoriesModel
  let target: AbacusDomain.Category.ID?
  @Binding var dragging: AbacusDomain.Category.ID?
  @Binding var dropTarget: CategoryDropTarget?

  /// Row height used to split it into before / onto / after.
  static let rowHeight: CGFloat = 30

  private func position(_ info: DropInfo) -> CategoryDropPosition {
    guard target != nil else { return .after }
    let y = info.location.y
    if y < Self.rowHeight * 0.28 { return .before }
    if y > Self.rowHeight * 0.72 { return .after }
    return .onto
  }

  private func allowed(_ info: DropInfo) -> CategoryDropPosition? {
    guard let dragging else { return nil }
    let position = position(info)
    if model.canDrop(dragging, on: target, position: position) { return position }
    // Nesting not possible (a parent with subcategories): fall back to a reorder.
    if position == .onto {
      let fallback: CategoryDropPosition = info.location.y < Self.rowHeight / 2 ? .before : .after
      if model.canDrop(dragging, on: target, position: fallback) { return fallback }
    }
    return nil
  }

  func validateDrop(info: DropInfo) -> Bool { dragging != nil }

  func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    guard let position = allowed(info) else {
      if dropTarget?.id == target { dropTarget = nil }
      return DropProposal(operation: .forbidden)
    }
    let next = CategoryDropTarget(id: target, position: position)
    if dropTarget != next { dropTarget = next }
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    if dropTarget?.id == target { dropTarget = nil }
  }

  func performDrop(info: DropInfo) -> Bool {
    defer {
      dropTarget = nil
      dragging = nil
    }
    guard let moving = dragging, let position = allowed(info) else { return false }
    Task { await model.drop(moving, on: target, position: position) }
    return true
  }
}

/// Drag handle, colour dot, name (parents bold, children indented), usage count; the drop
/// indicator (a line above / below, or the row outlined for "make a subcategory").
struct CategoryRowView: View {
  let row: CategoryRow
  let indicator: CategoryDropPosition?

  var body: some View {
    HStack(spacing: 10) {
      if row.isBuiltIn {
        Image(systemName: "pin.fill")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .frame(width: 8)
          .help("Built in: always on top")
      } else {
        ManageGrip()
      }
      ManageDot(hex: row.colorHex)
      HStack(spacing: 6) {
        Text(row.name)
          .fontWeight(row.isChild ? .regular : .semibold)
        if row.isArchived {
          badge("Archived")
        }
        if row.isBuiltIn {
          badge("Built in")
        }
      }
      .padding(.leading, row.isChild ? 18 : 0)
      .opacity(row.isArchived || !row.matchesSearch ? 0.55 : 1)
      Spacer(minLength: 8)
      Text(row.usage).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .font(.system(size: 13))
    .frame(minHeight: CategoryDropDelegate.rowHeight - 8)
    .padding(.vertical, 4)
    .contentShape(.rect)
    .overlay(alignment: indicator == .before ? .top : .bottom) {
      if indicator == .before || indicator == .after {
        Rectangle().fill(Color.accentColor).frame(height: 2)
          .padding(.leading, row.isChild ? 46 : 28)
      }
    }
    .overlay {
      if indicator == .onto {
        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
      }
    }
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

/// Name, parent, colour, usage; Archive and Delete…; Save at the bottom-right (R-CAT-1…3,
/// R-MGMT-10). The built-in "Uncategorised" shows its colour only (D47).
struct CategoryInspectorView: View {
  let model: CategoriesModel

  private func binding<Value>(_ keyPath: WritableKeyPath<CategoryDraft, Value>, _ fallback: Value) -> Binding<Value> {
    draftBinding({ model.draft }, { model.draft = $0 }, keyPath, fallback: fallback)
  }

  var body: some View {
    if let draft = model.draft {
      VStack(spacing: 0) {
        ManageInspector(title: model.inspectorTitle) {
          ManageField("Name") {
            if draft.isBuiltIn {
              Text(Uncategorised.title)
                .foregroundStyle(.secondary)
                .help("The built-in entry can't be renamed")
            } else {
              TextField("Name", text: binding(\.name, ""))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
          }
          if !draft.isBuiltIn {
            ManageField("Parent") {
              Picker("Parent", selection: binding(\.parentID, nil)) {
                Text("None (top level)").tag(AbacusDomain.Category.ID?.none)
                ForEach(model.parentOptions) { Text($0.name).tag(Optional($0.id)) }
              }
              .labelsHidden()
              .disabled(!model.canChangeParent)
              if !model.canChangeParent {
                Text("Has subcategories, so it stays at the top level.")
                  .font(.system(size: 11)).foregroundStyle(.secondary)
              }
            }
          }
          ManageField("Colour") {
            ManageColorField(hex: binding(\.colorHex, nil))
          }
          if !draft.isNew {
            ManageCard {
              Text(model.usageText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          }
          if !draft.isNew && !draft.isBuiltIn {
            HStack(spacing: 8) {
              Button(model.archiveTitle) { Task { await model.archiveOrUnarchive() } }
              Button("Delete…", role: .destructive) { model.requestDelete() }
                .foregroundStyle(ManagePalette.destructive)
            }
            .padding(.top, 4)
          }
        }
        CategorySaveFooter(model: model, isNew: draft.isNew)
      }
      .frame(width: ManageMetrics.inspectorWidth)
      .background(ManagePalette.inspectorBackground)
    } else {
      ManageInspector(title: "") {
        Text("Select a category or create one.").foregroundStyle(.secondary)
      }
    }
  }
}

/// Messages on the left, Revert / Cancel and the primary Save on the right, pinned to the
/// bottom of the inspector (R-MGMT-10).
struct CategorySaveFooter: View {
  let model: CategoriesModel
  let isNew: Bool

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if model.isDirty, let validation = model.validationMessage {
        Text(validation).font(.caption).foregroundStyle(ManagePalette.negative)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let error = model.errorMessage {
        Text(error).font(.caption).foregroundStyle(ManagePalette.negative)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 8) {
        Spacer()
        Button(isNew ? "Cancel" : "Revert", action: model.revert)
          .disabled(!model.isDirty)
        Button(isNew ? "Create" : "Save") { Task { await model.save() } }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canSave)
          .keyboardShortcut("s", modifiers: .command)
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .overlay(alignment: .top) { Divider() }
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
