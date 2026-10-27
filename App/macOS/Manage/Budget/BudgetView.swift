import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Budget screen (approved prototype group 4 as changed by TA v1.6, R-MGMT-3, R-MGMT-10,
/// R-BUD-1…3, D43, D46): "Applies from <month>", the total limit with its currency, per-category
/// limits each with its own currency, a share bar and a red trash button, the unallocated row
/// and the total row in the display currency (the toolbar switch); Revert and Save at the
/// bottom-right of the form.
public struct BudgetView: View {
  @State private var model: BudgetEditorModel
  /// The app's display currency (the toolbar switch); absent in bare previews.
  @Environment(AppModel.self) private var app: AppModel?

  public init(model: BudgetEditorModel) {
    _model = State(initialValue: model)
  }

  public init(dependencies: ManageDependencies) {
    self.init(model: BudgetEditorModel(dependencies: dependencies))
  }

  public var body: some View {
    ManagePhaseView(phase: model.phase, title: "Budget", retry: { await model.load() }) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          BudgetEditorContent(model: model)
          BudgetSaveBar(model: model)
        }
        .padding(20)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .navigationTitle("Monthly budget")
    .onChange(of: app?.displayCurrency, initial: true) { _, currency in
      if let currency { model.setDisplayCurrency(currency) }
    }
    .task {
      if model.phase == .idle { await model.load() }
      #if DEBUG
        await demoSaveStateForSnapshot()
      #endif
    }
    #if DEBUG
      // Sample data may arrive after the first load.
      .onChange(of: model.rows.count) { Task { await demoSaveStateForSnapshot() } }
    #endif
  }

  #if DEBUG
    @MainActor private static var demoed = false

    /// Debug builds (UI snapshots on a scratch database): `-AbacusBudgetDemo edited` changes the
    /// first limit; `-AbacusBudgetDemo saved` changes and saves it (D56 Save button states).
    private func demoSaveStateForSnapshot() async {
      guard !Self.demoed, let demo = UserDefaults.standard.string(forKey: "AbacusBudgetDemo"),
        let first = model.rows.first
      else { return }
      Self.demoed = true
      model.setLimit(model.limitText(first.categoryID) == "100" ? "200" : "100", for: first.categoryID)
      if demo == "saved" { await model.save() }    }
  #endif
}

/// Revert (left) and Save (right) at the bottom-right of the form (R-MGMT-10); the messages
/// above them.
struct BudgetSaveBar: View {
  let model: BudgetEditorModel

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      if let message = model.validationMessage, model.isDirty {
        Text(message).font(.callout).foregroundStyle(ManagePalette.negative)
      }
      if let error = model.errorMessage {
        Text(error).font(.callout).foregroundStyle(ManagePalette.negative)
      }
      HStack(spacing: 8) {
        if model.isDirty {
          Text("Unsaved changes").font(.callout).foregroundStyle(.secondary)
        } else if let saved = model.savedMessage {
          Label(saved, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button("Revert") { Task { await model.revert() } }
          .disabled(!model.isDirty)
        Button {
          Task { await model.save() }
        } label: {
          if model.saveState == .saved {
            Label("Saved", systemImage: "checkmark")
          } else {
            Text("Save")
          }
        }
        .buttonStyle(BudgetSaveButtonStyle(isSaved: model.saveState == .saved))
        .disabled(!model.canSave)
        .keyboardShortcut("s", modifiers: .command)
        .accessibilityLabel(model.saveState == .saved ? "Saved" : "Save")
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .font(.system(size: 13))
  }
}

/// The Budget Save button (D56): blue ("Save"; dimmed while there is nothing to save), green
/// with a checkmark ("Saved", disabled) right after a save until the next edit. A custom style
/// because a disabled bordered-prominent button loses its colour on macOS.
struct BudgetSaveButtonStyle: ButtonStyle {
  let isSaved: Bool
  @Environment(\.isEnabled) private var isEnabled

  static let saved = ManagePalette.dynamic(light: 0x1E8E3E, dark: 0x30A64A)

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .frame(minWidth: 64)
      .background(isSaved ? Self.saved : Color.accentColor, in: .rect(cornerRadius: 6))
      .opacity(isEnabled || isSaved ? 1 : 0.45)
      .brightness(configuration.isPressed ? -0.08 : 0)
      .animation(.easeOut(duration: 0.15), value: isSaved)
  }
}

struct BudgetEditorContent: View {
  @Bindable var model: BudgetEditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .bottom, spacing: 16) {
        ManageField("Applies from") {
          Picker("Applies from", selection: Binding(get: { model.appliesFrom }, set: { month in Task { await model.setAppliesFrom(month) } })) {
            ForEach(model.monthOptions, id: \.self) { Text(model.monthTitle($0)).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
        ManageField("Total limit") {
          HStack(spacing: 6) {
            TextField("No total", text: $model.totalLimit)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .monospacedDigit()
              .frame(width: 120)
              .accessibilityLabel("Total limit")
            Picker("Total currency", selection: $model.totalCurrency) {
              ForEach(Currency.displayOrder, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
          }
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
            Text(model.addOptionTitle(category)).tag(Optional(category.id))
          }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.addOptions.isEmpty)
        Button("Add category limit") { model.addLimit() }
          .disabled(model.addOptions.isEmpty)
      }
      .font(.system(size: 13))
    }
  }
}

/// Category | Monthly limit | Currency | Share | trash, then the unallocated row and the total
/// row in the display currency (R-BUD-1, D46).
struct BudgetLimitsTable: View {
  let model: BudgetEditorModel

  static let columns: [ManageColumns.Column] = [.flex(2), .fixed(120), .fixed(76), .flex(1), .fixed(28)]

  var body: some View {
    VStack(spacing: 0) {
      ManageColumns(columns: Self.columns) {
        Text("Category")
        Text("Monthly limit").frame(maxWidth: .infinity, alignment: .trailing)
        Text("Currency")
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
          Picker(
            "Currency for \(row.name)",
            selection: Binding(get: { model.currency(row.categoryID) }, set: { model.setCurrency($0, for: row.categoryID) })
          ) {
            ForEach(Currency.displayOrder, id: \.self) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
          ManageBar(fraction: row.share, color: ManagePalette.hex(row.colorHex))
          Button {
            model.removeLimit(row.categoryID)
          } label: {
            Image(systemName: "trash").frame(width: 28, height: 28)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
          .accessibilityLabel("Remove \(row.name)")
          .help("Remove the limit")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
      }

      if model.hasTotal {
        Divider()
        ManageColumns(columns: Self.columns) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Unallocated")
            Text(model.unallocatedNote)
              .font(.system(size: 11))
              .foregroundStyle((model.unallocated?.minorUnits ?? 0) < 0 ? ManagePalette.negative : Color.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text(model.unallocatedText)
            .monospacedDigit()
            .foregroundStyle((model.unallocated?.minorUnits ?? 0) < 0 ? ManagePalette.negative : Color.primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
          Text(model.displayCurrency.rawValue).foregroundStyle(.secondary)
          ManageBar(fraction: model.unallocatedShare, color: .secondary)
          Color.clear.frame(height: 1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
      }

      Divider()
      ManageColumns(columns: Self.columns) {
        Text("Total in \(model.displayCurrency.rawValue)").fontWeight(.medium)
        Text(model.totalText)
          .fontWeight(.semibold)
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
        Color.clear.frame(height: 1)
        Text(model.totalNote)
          .font(.system(size: 12))
          .foregroundStyle(model.currenciesWithoutRate.isEmpty ? Color.secondary : ManagePalette.negative)
          .fixedSize(horizontal: false, vertical: true)
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
