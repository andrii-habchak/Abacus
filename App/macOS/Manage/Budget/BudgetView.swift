import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Budget screen (approved prototype group 4, R-MGMT-3, R-BUD-1…3): total + currency,
/// "Applies from <month>", per-category limits with share bars, the unallocated row (red when
/// the limits exceed the total), add / remove limits; "Save budget" in the toolbar.
public struct BudgetView: View {
  @State private var model: BudgetEditorModel

  public init(model: BudgetEditorModel) {
    _model = State(initialValue: model)
  }

  public init(dependencies: ManageDependencies) {
    self.init(model: BudgetEditorModel(dependencies: dependencies))
  }

  public var body: some View {
    ManagePhaseView(phase: model.phase, title: "Budget", retry: { await model.load() }) {
      ScrollView {
        BudgetEditorContent(model: model)
          .padding(20)
          .frame(maxWidth: 760, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .navigationTitle("Monthly budget")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Save budget") { Task { await model.save() } }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canSave)
          .keyboardShortcut("s", modifiers: .command)
      }
    }
    .task { if model.phase == .idle { await model.load() } }
  }
}

struct BudgetEditorContent: View {
  @Bindable var model: BudgetEditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .bottom, spacing: 16) {
        ManageField("Total monthly budget") {
          HStack(spacing: 6) {
            TextField("Total monthly budget", text: $model.total)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .font(.system(size: 15, weight: .semibold))
              .multilineTextAlignment(.trailing)
              .monospacedDigit()
              .frame(width: 130)
            Picker("Budget currency", selection: $model.currency) {
              ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
          }
        }
        ManageField("Applies from") {
          Picker("Applies from", selection: Binding(get: { model.appliesFrom }, set: { month in Task { await model.setAppliesFrom(month) } })) {
            ForEach(model.monthOptions, id: \.self) { Text(model.monthTitle($0)).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
        Text(model.appliesNote)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.system(size: 13))

      BudgetLimitsTable(model: model)

      HStack(spacing: 8) {
        Picker("Category to add", selection: $model.categoryToAdd) {
          ForEach(model.addOptions) { category in
            Text(category.parentID == nil ? category.name : "    \(category.name)").tag(Optional(category.id))
          }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.addOptions.isEmpty)
        Button("Add category limit") { model.addLimit() }
          .disabled(model.addOptions.isEmpty)
      }
      .font(.system(size: 13))

      if let message = model.validationMessage, model.isDirty {
        Text(message).font(.callout).foregroundStyle(ManagePalette.negative)
      }
      if let error = model.errorMessage {
        Text(error).font(.callout).foregroundStyle(ManagePalette.negative)
      }
      if let saved = model.savedMessage {
        Label(saved, systemImage: "checkmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Category | Monthly limit | Share | ✕, then the Unallocated row (R-BUD-1).
struct BudgetLimitsTable: View {
  let model: BudgetEditorModel

  static let columns: [ManageColumns.Column] = [.flex(2), .fixed(140), .flex(1), .fixed(28)]

  var body: some View {
    VStack(spacing: 0) {
      ManageColumns(columns: Self.columns) {
        Text("Category")
        Text("Monthly limit").frame(maxWidth: .infinity, alignment: .trailing)
        Text("Share")
        Color.clear.frame(height: 1)
      }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .background(ManagePalette.headerBackground)

      ForEach(model.rows) { row in
        Divider()
        ManageColumns(columns: Self.columns) {
          HStack(spacing: 8) {
            ManageDot(hex: row.colorHex)
            Text(row.name).lineLimit(1)
            if !row.covers.isEmpty {
              Text(row.covers).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          TextField(
            "Monthly limit for \(row.name)",
            text: Binding(get: { model.limitText(row.categoryID) }, set: { model.setLimit($0, for: row.categoryID) })
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .overlay(
            RoundedRectangle(cornerRadius: 5).strokeBorder(ManagePalette.negative).opacity(row.isValid ? 0 : 1))
          ManageBar(fraction: row.share, color: ManagePalette.hex(row.colorHex))
          Button {
            model.removeLimit(row.categoryID)
          } label: {
            Image(systemName: "xmark").frame(width: 28, height: 28)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Remove \(row.name)")
          .help("Remove the limit")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
      }

      Divider()
      ManageColumns(columns: Self.columns) {
        Text("Unallocated (other categories)").foregroundStyle(.secondary)
        Text(model.unallocatedText)
          .fontWeight(.semibold)
          .monospacedDigit()
          .foregroundStyle(model.isOverAllocated ? ManagePalette.destructive : Color.primary)
          .frame(maxWidth: .infinity, alignment: .trailing)
        Text(model.unallocatedNote)
          .font(.system(size: 12))
          .foregroundStyle(model.isOverAllocated ? ManagePalette.destructive : Color.secondary)
        Color.clear.frame(height: 1)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .background(ManagePalette.headerBackground)
    }
    .font(.system(size: 13))
    .background(ManagePalette.card)
    .clipShape(.rect(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ManagePalette.border))
  }
}

#Preview("Budget") {
  BudgetView(dependencies: .preview())
    .frame(width: 900, height: 640)
}
