import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Categories screen (approved prototype group 4, R-MGMT-2, R-CAT-1…3): Expense / Income
/// tabs, the one-level tree with drag handles and usage counts, the inspector; "New subcategory"
/// and "New category" in the toolbar; Delete… asks where a used category's transactions go.
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
        Button("New subcategory") { model.newSubcategory() }
          .disabled(!model.canAddSubcategory)
          .help("New subcategory under the selected category")
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

/// Kind tabs and the reorderable tree (R-MGMT-2).
struct CategoriesTree: View {
  let model: CategoriesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Picker("Kind", selection: Binding(get: { model.kind }, set: { model.setKind($0) })) {
        Text("Expense").tag(CategoryKind.expense)
        Text("Income").tag(CategoryKind.income)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .padding(.horizontal, ManageMetrics.horizontalPadding)
      .padding(.top, 12)
      .padding(.bottom, 6)
      List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
        ForEach(model.rows) { row in
          CategoryRowView(row: row).tag(row.id)
        }
        .onMove { source, destination in
          Task { await model.move(fromOffsets: source, toOffset: destination) }
        }
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
    }
  }
}

/// Drag handle, colour dot, name (parents bold, children indented), usage count.
struct CategoryRowView: View {
  let row: CategoryRow

  var body: some View {
    HStack(spacing: 10) {
      ManageGrip()
      ManageDot(hex: row.colorHex)
      HStack(spacing: 6) {
        Text(row.name)
          .fontWeight(row.isChild ? .regular : .semibold)
        if row.isArchived {
          Text("Archived")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(ManagePalette.badge, in: .capsule)
        }
      }
      .padding(.leading, row.isChild ? 18 : 0)
      .opacity(row.isArchived ? 0.6 : 1)
      Spacer(minLength: 8)
      Text(row.usage).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .font(.system(size: 13))
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

/// Name, parent, colour, usage; Archive and Delete… (R-CAT-1…3).
struct CategoryInspectorView: View {
  let model: CategoriesModel

  private func binding<Value>(_ keyPath: WritableKeyPath<CategoryDraft, Value>, _ fallback: Value) -> Binding<Value> {
    draftBinding({ model.draft }, { model.draft = $0 }, keyPath, fallback: fallback)
  }

  var body: some View {
    if let draft = model.draft {
      ManageInspector(title: model.inspectorTitle) {
        ManageField("Name") {
          TextField("Name", text: binding(\.name, ""))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
        }
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
        ManageField("Colour") {
          HStack(spacing: 6) {
            ForEach(ManageText.swatches, id: \.self) { hex in
              Button {
                model.draft?.colorHex = hex
              } label: {
                ManageDot(hex: hex, size: 22)
                  .overlay(
                    Circle()
                      .strokeBorder(ManagePalette.hex(hex), lineWidth: 2)
                      .padding(-4)
                      .opacity(draft.colorHex == hex ? 1 : 0))
                  .padding(4)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Colour \(hex)")
              .accessibilityAddTraits(draft.colorHex == hex ? .isSelected : [])
            }
          }
        }
        if !draft.isNew {
          ManageCard {
            Text(model.usageText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
              .foregroundStyle(ManagePalette.destructive)
          }
          .padding(.top, 4)
        }
      }
    } else {
      ManageInspector(title: "") {
        Text("Select a category or create one.").foregroundStyle(.secondary)
      }
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
