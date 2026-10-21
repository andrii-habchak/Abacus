import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The transaction editor sheet (approved prototype 3). Present it from the shell's "New
/// transaction" (⌘N) or the list's double-click / Return:
///
/// ```swift
/// .sheet(item: $editorMode) { mode in
///   TransactionEditor(mode: mode, dependencies: editorDependencies) { result in
///     editorMode = nil
///     if result != .cancelled { Task { await transactions.reload() } }
///   }
/// }
/// ```
struct TransactionEditor: View {
  @State private var model: TransactionEditorModel
  let onDone: (TransactionEditorResult) -> Void

  init(
    mode: TransactionEditorMode, dependencies: TransactionEditorDependencies,
    onDone: @escaping (TransactionEditorResult) -> Void
  ) {
    _model = State(initialValue: TransactionEditorModel(mode: mode, dependencies: dependencies))
    self.onDone = onDone
  }

  var body: some View {
    TransactionEditorSheet(model: model, onDone: onDone)
      .task {
        if !model.isLoaded { await model.load() }
      }
  }
}
