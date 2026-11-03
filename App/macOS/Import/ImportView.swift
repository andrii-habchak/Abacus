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
  /// N6: "Reconcile <account>" on the Done step of a PKO import (the statement's closing balance).
  var onReconcile: (ImportReconcileOffer) -> Void

  @State private var isDropTargeted = false

  init(
    model: ImportWizardModel, onShowTransactions: @escaping (ImportBatch.ID) -> Void = { _ in },
    onReconcile: @escaping (ImportReconcileOffer) -> Void = { _ in }, onDataChanged: @escaping () -> Void = {}
  ) {
    _model = State(initialValue: model)
    self.onShowTransactions = onShowTransactions
    self.onReconcile = onReconcile
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
            ImportHistoryPanel(model: model, showTransactions: onShowTransactions)
              .transition(.move(edge: .trailing))
          }
        }
    }
    // Fill the window instead of sizing it. The leak itself was the choose-file paragraph's
    // vertical fixedSize (see ImportChooseFileStep); this frame keeps any step's minimum or ideal
    // height from resizing the window again.
    .frame(minWidth: 0, idealWidth: 900, maxWidth: .infinity, minHeight: 0, idealHeight: 600, maxHeight: .infinity)
    .background(ImportPalette.surface)
    .navigationTitle("Import")
    .disabled(model.activity == .committing || model.activity == .undoing || model.activity == .moving)
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
      // Takes the batch before the dialog's dismissal clears it (C41).
      Button("Undo import", role: .destructive) { model.startConfirmedUndo() }
      Button("Cancel", role: .cancel) { model.cancelUndo() }
    } message: {
      Text(model.undoConfirmationMessage)
    }
    .alert(
      "Import undone",
      isPresented: Binding(get: { model.undoNotice != nil }, set: { if !$0 { model.undoNotice = nil } })
    ) {
      Button("OK") { model.undoNotice = nil }
    } message: {
      Text(model.undoNotice ?? "")
    }
    // C44: History → Move to another account.
    .sheet(isPresented: Binding(get: { model.moveSheet != nil }, set: { if !$0 { model.cancelMove() } })) {
      if let sheet = model.moveSheet {
        ImportMoveSheet(model: model, sheet: sheet)
      }
    }
    .alert(
      "Transactions moved",
      isPresented: Binding(get: { model.moveNotice != nil }, set: { if !$0 { model.moveNotice = nil } })
    ) {
      // C45: OK first, so it is the blue default button; Undo move is the plain one. Undo move
      // takes the move before the alert's dismissal clears the notice.
      ForEach(model.moveNoticeButtons, id: \.self) { button in
        switch button.action {
        case .dismiss: Button(button.title) { model.moveNotice = nil }.keyboardShortcut(.defaultAction)
        case .undoMove: Button(button.title) { model.startUndoLastMove() }
        }
      }
    } message: {
      Text(model.moveNotice ?? "")
    }
    .task {
      model.onDataChanged = onDataChanged
      await model.load()
      #if DEBUG
        // UI checks: `-AbacusImportFile <csv>` opens the review step, e.g. for an in-app snapshot.
        if model.step == .chooseFile, let path = UserDefaults.standard.string(forKey: "AbacusImportFile") {
          // A demo waits for the sample data's accounts, which load alongside this screen.
          if UserDefaults.standard.string(forKey: "AbacusImportDemo") != nil {
            for _ in 0..<50 where model.accounts.count < 2 {
              try? await Task.sleep(for: .milliseconds(100))
              await model.refreshReference()
            }
          }
          await model.open(url: URL(filePath: path))
          // `-AbacusImportAccount <name>`: the statement's account when the file does not name it.
          if model.needsTargetAccount, let name = UserDefaults.standard.string(forKey: "AbacusImportAccount") {
            // Sample data may still be loading: wait for the account a few seconds.
            for _ in 0..<20 where !model.accounts.contains(where: { $0.name == name }) {
              try? await Task.sleep(for: .milliseconds(250))
              await model.refreshReference()
            }
            if let account = model.accounts.first(where: { $0.name == name }) { await model.chooseTargetAccount(account.id) }
          }
          if UserDefaults.standard.bool(forKey: "AbacusImportResolveReview") { resolveReviewForSnapshot() }
          await openDebugDemo()
          // `-AbacusImportReviewFilter pending|gaps|decisions|categories`: the Needs review sub-tab;
          // `-AbacusImportCard <status>` presses a summary card; `-AbacusImportCommit YES` imports
          // (the Done step).
          let defaults = UserDefaults.standard
          if let card = defaults.string(forKey: "AbacusImportCard"), let status = RowStatus(rawValue: card) {
            model.selectFilter(status)
          }
          if let name = defaults.string(forKey: "AbacusImportReviewFilter") {
            model.tab = .review
            switch name {
            case "pending": model.reviewFilter = .pending
            case "gaps": model.reviewFilter = .gaps
            case "decisions": model.reviewFilter = .decisions
            case "categories": model.reviewFilter = .categories
            default: break
            }
          }
          // `-AbacusImportStale keep|markSettled|delete`: decides every stale pending hold.
          if let choice = defaults.string(forKey: "AbacusImportStale").flatMap(ImportStaleChoice.init(rawValue:)) {
            model.setStale(choice, ids: model.staleItems.compactMap { UUID(uuidString: $0.id) })
          }
          if defaults.bool(forKey: "AbacusImportCommit") { await model.commit() }
        }
      #endif
    }
    .animation(.easeOut(duration: 0.18), value: model.isHistoryShown)
    // A category created in another window or screen shows up in the row pickers (C31).
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.refreshReference() }
    }
    .onAppear { Task { await model.refreshReference() } }
  }

  #if DEBUG
    /// UI checks: with `-AbacusImportFile`, `-AbacusImportResolveReview YES` resolves the Needs
    /// review cards as a user would, so a snapshot shows their rule lines: a transfer to an own
    /// account in another currency → that account with an estimated (or typed) other side; an
    /// unknown type → its sign's kind and the first category, except the last such card, which only
    /// confirms the suggestion (the hint without a category).
    private func resolveReviewForSnapshot() {
      model.tab = .review
      model.reviewFilter = .decisions
      let records = model.reviewItems.filter { !$0.title.hasPrefix("Transfer to an own account") }
      for item in model.reviewItems {
        if item.title.hasPrefix("Transfer to an own account") {
          model.selectReviewOption(.transfer, forRow: item.id)
          if let picker = model.counterpartPicker {
            if picker.model.estimate != nil {
              model.useEstimatedCounterpart()
            } else {
              picker.model.manualText = "100.00"
              model.useManualCounterpart()
            }
          }
        } else if case .record(let kind) = item.suggested {
          model.selectReviewOption(.record(kind), forRow: item.id)
          guard item.id != records.last?.id || records.count == 1 else { continue }
          let first = item.categoryOptions.lazy.compactMap { option -> AbacusDomain.Category.ID? in
            if case .existing(let id) = option.choice { id } else { nil }
          }.first
          if let first { model.selectReviewCategory(first, forRow: item.id) }
        }
      }
    }

    /// UI checks (in-app snapshot) after `-AbacusImportFile`: `-AbacusImportDemo counterpart:<account
    /// name>` opens "Find the other side…" of the first row that needs it for that account
    /// (`-AbacusImportTarget <account name>` picks the statement's account first);
    /// `-AbacusImportDemo moved:<account name>` imports the file into the chosen statement account,
    /// moves the batch to the named account and shows the "Transactions moved" alert;
    /// `-AbacusImportDemo history:<any account name>` imports the file and opens History.
    private func openDebugDemo() async {
      guard let demo = UserDefaults.standard.string(forKey: "AbacusImportDemo"),
        let colon = demo.firstIndex(of: ":")
      else { return }
      let kind = demo[..<colon]
      let name = String(demo[demo.index(after: colon)...])
      guard let account = model.accounts.first(where: { $0.name == name }) else { return }
      // `-AbacusImportTarget <account name>`: the statement's account when the file doesn't say.
      if model.needsTargetAccount, let target = UserDefaults.standard.string(forKey: "AbacusImportTarget"),
        let statement = model.accounts.first(where: { $0.name == target })
      {
        await model.chooseTargetAccount(statement.id)
      }
      switch kind {
      case "counterpart":
        if let row = model.rowItems.first(where: { model.needsCounterpart(forRow: $0.id, to: account.id) }) {
          model.beginCounterpart(forRow: row.id, to: account.id)
        }
      case "moved":
        await model.commit()
        guard let batch = model.history.first else { return }
        await model.requestMove(batch)
        model.moveSheet?.targetAccountID = account.id
        await model.startMove()?.value
      case "history":
        await model.commit()
        model.isHistoryShown = true
      default: break
      }
    }
  #endif

  @ViewBuilder
  private var content: some View {
    switch model.step {
    case .chooseFile:
      ImportChooseFileStep(isTargeted: isDropTargeted, chooseFile: chooseFile)
    case .review:
      ImportReviewStep(model: model)
    case .done:
      ImportDoneStep(model: model, isTargeted: isDropTargeted, onReconcile: onReconcile) {
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
    case .moving: "Moving the transactions…"
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

/// "Choose file → Review → Done" (no numbers: they read as a file count), History, Choose file….
struct ImportStepBar: View {
  let model: ImportWizardModel
  let chooseFile: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      HStack(spacing: 6) {
        ForEach(ImportWizardModel.Step.allCases, id: \.self) { step in
          if step != ImportWizardModel.Step.allCases.first {
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
          }
          let colors =
            step == model.step
            ? ImportPalette.stepCurrent : step.rawValue < model.step.rawValue ? ImportPalette.stepDone : ImportPalette.stepNext
          Text(step.title)
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
      // No vertical fixedSize here: the window measures its minimum size with a zero width, where
      // a fixed-height paragraph wraps one glyph per line and became a 2,251 pt minimum height.
      .frame(maxWidth: 460)
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
  var isTargeted = false
  var onReconcile: (ImportReconcileOffer) -> Void = { _ in }
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
        Button("Undo import") { model.requestUndoOfLastImport() }
        Button("Show transactions", action: showTransactions)
          .buttonStyle(.borderedProminent)
      }
      .padding(.top, 6)
      if let offer = model.reconcileOffer {
        VStack(spacing: 6) {
          Text("Check this account against the statement")
            .font(.system(size: 13, weight: .semibold))
          Text("The file closes at \(offer.closingText) on \(offer.dayText). Reconcile \(offer.accountName) with this balance and date filled in.")
            .font(.system(size: 12))
            .foregroundStyle(ImportPalette.label)
            .multilineTextAlignment(.center)
          Button("Reconcile \(offer.accountName)") { onReconcile(offer) }
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 10).fill(ImportPalette.accentFill))
      }
      // The next file can be dropped right here (C31).
      VStack(spacing: 6) {
        Image(systemName: "arrow.down.doc")
          .font(.system(size: 24, weight: .light))
          .foregroundStyle(.secondary)
        Text("Drop a CSV export here")
          .font(.system(size: 14, weight: .semibold))
        Text("to import the next file")
          .font(.system(size: 12))
          .foregroundStyle(ImportPalette.label)
      }
      .padding(.vertical, 22)
      .frame(maxWidth: 420)
      .background(RoundedRectangle(cornerRadius: 12).fill(isTargeted ? ImportPalette.accentFill : ImportPalette.dropZone))
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(
            isTargeted ? ImportPalette.accent : ImportPalette.dropBorder, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
      )
      .padding(.top, 18)
    }
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.top, 40)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - History

/// The import history (R-IMP-6): batches with their counts, "Show transactions", "Move to another
/// account…" (C44) and "Undo import"; undone ones greyed with their buttons disabled.
struct ImportHistoryPanel: View {
  let model: ImportWizardModel
  var showTransactions: (ImportBatch.ID) -> Void = { _ in }

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
            ImportHistoryEntry(
              item: item, transactionCount: model.batchCounts[item.id], showTransactions: { showTransactions(item.id) },
              moveUnavailableReason: model.moveUnavailableReason(item.batch),
              move: { Task { await model.requestMove(item.batch) } }
            ) {
              model.requestUndo(item.batch)
            }
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
  /// C41: transactions the batch still has; nil = unknown.
  var transactionCount: Int? = nil
  var showTransactions: () -> Void = {}
  /// C44: why "Move to another account" is disabled; nil = enabled.
  var moveUnavailableReason: String? = nil
  var move: () -> Void = {}
  let undo: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(item.file)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(2)
        Spacer(minLength: 0)
        if item.isUndone {
          ImportBadge(text: "Undone", colors: ImportPalette.badge(.skipped))
        }
        Text(item.when)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      Text(item.summary)
        .font(.system(size: 12))
        .foregroundStyle(ImportPalette.label)
        .fixedSize(horizontal: false, vertical: true)
      if !item.isUndone, let transactionCount {
        Text(
          transactionCount == 0
            ? "No transactions of its own (rows already imported, skipped or linked)"
            : "\(transactionCount.formatted()) transaction\(transactionCount == 1 ? "" : "s") from this import")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      if item.isUndone {
        Text("Undone — its transactions were removed")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      // One line when the panel is wide enough, else Move on a line of its own.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          Spacer(minLength: 0)
          showButton
          moveButton
          undoButton
        }
        VStack(alignment: .trailing, spacing: 6) {
          moveButton
          HStack(spacing: 6) {
            showButton
            undoButton
          }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(ImportPalette.border))
    .opacity(item.isUndone ? 0.6 : 1)
  }

  private var showButton: some View {
    Button("Show transactions", action: showTransactions)
      .controlSize(.small)
      .disabled(item.isUndone)
  }

  private var moveButton: some View {
    Button(ImportWizardModel.moveActionTitle, action: move)
      .controlSize(.small)
      .disabled(moveUnavailableReason != nil)
      .help(moveUnavailableReason ?? "Move this statement's transactions to another account in the same currency")
  }

  /// R-IMP-6: asks for the confirmation first; disabled once the import is undone (C44).
  private var undoButton: some View {
    Button("Undo import", action: undo)
      .controlSize(.small)
      .disabled(item.isUndone)
      .help(item.isUndone ? "This import is undone." : "Remove this import's transactions")
  }
}
