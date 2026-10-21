import AbacusDomain
import AbacusFeatures
import AbacusImport
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Import screen (approved prototype 5; R-IMP-1…8): step bar with History and Choose file…,
/// then Choose file → Review → Done, and the History panel with Undo.
///
/// The shell routes `.importFiles` here. Either pass a model it keeps alive (so a half-reviewed
/// file survives switching sections) or the dependencies (`ImportWizardDependencies.live(database:)`).
/// `onShowTransactions` gets the imported batch; `onDataChanged` runs after a commit or an undo.
struct ImportView: View {
  @State private var model: ImportWizardModel
  var onShowTransactions: (ImportBatch.ID) -> Void
  var onDataChanged: () -> Void

  @State private var isDropTargeted = false

  init(
    model: ImportWizardModel, onShowTransactions: @escaping (ImportBatch.ID) -> Void = { _ in },
    onDataChanged: @escaping () -> Void = {}
  ) {
    _model = State(initialValue: model)
    self.onShowTransactions = onShowTransactions
    self.onDataChanged = onDataChanged
  }

  init(
    dependencies: ImportWizardDependencies, onShowTransactions: @escaping (ImportBatch.ID) -> Void = { _ in },
    onDataChanged: @escaping () -> Void = {}
  ) {
    self.init(
      model: ImportWizardModel(dependencies: dependencies), onShowTransactions: onShowTransactions,
      onDataChanged: onDataChanged)
  }

  var body: some View {
    VStack(spacing: 0) {
      ImportStepBar(model: model, chooseFile: chooseFile)
      ImportRule()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
          if model.isHistoryShown {
            ImportHistoryPanel(model: model)
              .transition(.move(edge: .trailing))
          }
        }
    }
    .background(ImportPalette.surface)
    .navigationTitle("Import")
    .disabled(model.activity == .committing || model.activity == .undoing)
    .overlay { busyOverlay }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first else { return false }
      Task { await model.open(url: url) }
      return true
    } isTargeted: { isDropTargeted = $0 }
    .alert(
      "Import",
      isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .confirmationDialog(
      model.undoConfirmationTitle,
      isPresented: Binding(get: { model.pendingUndo != nil }, set: { if !$0 { model.cancelUndo() } })
    ) {
      Button("Undo Import", role: .destructive) { Task { await model.confirmUndo() } }
      Button("Cancel", role: .cancel) { model.cancelUndo() }
    } message: {
      Text(model.undoConfirmationMessage)
    }
    .task {
      model.onDataChanged = onDataChanged
      await model.load()
    }
    .animation(.easeOut(duration: 0.18), value: model.isHistoryShown)
  }

  @ViewBuilder
  private var content: some View {
    switch model.step {
    case .chooseFile:
      ImportChooseFileStep(isTargeted: isDropTargeted, chooseFile: chooseFile)
    case .review:
      ImportReviewStep(model: model)
    case .done:
      ImportDoneStep(model: model) {
        if let id = model.summary?.batch.id { onShowTransactions(id) }
      }
    }
  }

  @ViewBuilder
  private var busyOverlay: some View {
    let text: String? = switch model.activity {
    case .reading, .previewing: "Reading the file…"
    case .committing: "Importing — nothing is saved unless everything succeeds…"
    case .undoing: "Undoing the import…"
    case .idle: nil
    }
    if let text {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text(text).font(.system(size: 13))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
  }

  /// The open panel for a CSV export (R-IMP-1).
  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.title = "Choose a file to import"
    panel.message = "Choose a Saldo export or a PKO BP statement (“Zestawienie operacji”)."
    panel.prompt = "Choose"
    panel.allowedContentTypes = [.commaSeparatedText, .plainText]
    panel.allowsOtherFileTypes = true
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    let handle: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      Task { await model.open(url: url) }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: handle)
    } else {
      panel.begin(completionHandler: handle)
    }
  }
}

// MARK: - Step bar

/// "1 Choose file · 2 Review · 3 Done", History, Choose file….
struct ImportStepBar: View {
  let model: ImportWizardModel
  let chooseFile: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      HStack(spacing: 6) {
        ForEach(ImportWizardModel.Step.allCases, id: \.self) { step in
          let colors =
            step == model.step
            ? ImportPalette.stepCurrent : step.rawValue < model.step.rawValue ? ImportPalette.stepDone : ImportPalette.stepNext
          Text("\(step.rawValue)  \(step.title)")
            .font(.system(size: 12, weight: step == model.step ? .semibold : .regular))
            .foregroundStyle(colors.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(colors.fill))
            .accessibilityAddTraits(step == model.step ? .isSelected : [])
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Step \(model.step.rawValue) of 3: \(model.step.title)")
      Spacer(minLength: 0)
      Button("History") { model.toggleHistory() }
        .controlSize(.regular)
      Button("Choose file…", action: chooseFile)
        .buttonStyle(.borderedProminent)
        .disabled(model.isBusy)
    }
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.vertical, 10)
  }
}

// MARK: - Step 1

struct ImportChooseFileStep: View {
  let isTargeted: Bool
  let chooseFile: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "arrow.down.doc")
        .font(.system(size: 36, weight: .light))
        .foregroundStyle(.secondary)
      Text("Drop a CSV export here")
        .font(.system(size: 17, weight: .semibold))
      Text(
        "Saldo exports and PKO BP statements (“Zestawienie operacji”) are recognised automatically. "
          + "Nothing is saved until you confirm the preview."
      )
      .font(.system(size: 13))
      .foregroundStyle(ImportPalette.label)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 460)
      .fixedSize(horizontal: false, vertical: true)
      Button("Choose file…", action: chooseFile)
        .padding(.top, 2)
    }
    .padding(.vertical, 40)
    .padding(.horizontal, 24)
    .frame(maxWidth: 640)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(isTargeted ? ImportPalette.accentFill : ImportPalette.dropZone)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(
          isTargeted ? ImportPalette.accent : ImportPalette.dropBorder, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
    )
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.top, 28)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Step 3

struct ImportDoneStep: View {
  let model: ImportWizardModel
  let showTransactions: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(ImportPalette.success)
      Text(model.doneTitle)
        .font(.system(size: 19, weight: .semibold))
      VStack(spacing: 4) {
        ForEach(model.doneLines, id: \.self) { line in
          Text(line)
        }
      }
      .font(.system(size: 13))
      .foregroundStyle(ImportPalette.label)
      .multilineTextAlignment(.center)
      HStack(spacing: 10) {
        Button("Undo this import") { model.requestUndoOfLastImport() }
        Button("Show transactions", action: showTransactions)
          .buttonStyle(.borderedProminent)
      }
      .padding(.top, 6)
    }
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.top, 40)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - History

/// The import history (R-IMP-6): batches with their counts, "Undo import…", undone ones greyed.
struct ImportHistoryPanel: View {
  let model: ImportWizardModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Import history")
          .font(.system(size: 15, weight: .semibold))
        Spacer()
        Button {
          model.toggleHistory()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close history")
      }
      if model.historyItems.isEmpty {
        Text("No imports yet.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .padding(.top, 8)
      }
      ScrollView {
        VStack(spacing: 10) {
          ForEach(model.historyItems) { item in
            ImportHistoryEntry(item: item) { model.requestUndo(item.batch) }
          }
        }
      }
      .scrollIndicators(.automatic)
    }
    .padding(16)
    .frame(width: ImportMetrics.historyWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(ImportPalette.surface)
    .overlay(alignment: .leading) {
      Rectangle().fill(ImportPalette.rule).frame(width: 1)
    }
    .shadow(color: .black.opacity(0.08), radius: 15, x: -12)
  }
}

struct ImportHistoryEntry: View {
  let item: ImportHistoryItem
  let undo: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(item.file)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(2)
        Spacer(minLength: 0)
        Text(item.when)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      Text(item.summary)
        .font(.system(size: 12))
        .foregroundStyle(ImportPalette.label)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        if item.isUndone {
          Text("Undone — its transactions were removed")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else {
          Button("Undo import…", action: undo)
            .controlSize(.small)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(ImportPalette.border))
    .opacity(item.isUndone ? 0.6 : 1)
  }
}
