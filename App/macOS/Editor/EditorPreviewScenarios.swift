import AbacusDomain
import AbacusFeatures
import Foundation
import SwiftUI

/// Editor states on `PreviewData` for previews and the owner's screenshots.
enum EditorPreviewScenario: String, CaseIterable {
  /// New expense with the last-used currency/account, a rule suggestion and the currency picker.
  case newExpense
  /// EUR purchase on a PLN account: "Charged to account" pre-filled, event pre-selected.
  case foreignExpense
  /// Monobank UAH → Revolut EUR with the amount received and the implied rate.
  case transfer
  /// Editing the Lidl purchase (cashback line) with a fee added.
  case editWithFee

  @MainActor
  func makeModel() async -> TransactionEditorModel {
    switch self {
    case .newExpense:
      let model = TransactionEditorModel.preview()
      await model.load()
      model.payee = "Uber"
      model.amountText = "18.40"
      return model
    case .foreignExpense:
      let model = TransactionEditorModel.preview(
        dependencies: .preview(now: Self.date("2026-10-18", hour: 13, minute: 20)))
      await model.load()
      model.accountID = PreviewData.pkoPersonal.id
      model.currencyCode = "EUR"
      model.amountText = "24.50"
      model.payee = "Café du Parc"
      model.categoryID = PreviewData.id(203)
      model.note = "Lunch with the team"
      return model
    case .transfer:
      let model = TransactionEditorModel.preview()
      await model.load()
      model.type = .transfer
      model.amountText = "4400"
      model.toAmountText = "100"
      model.payee = "To EUR card"
      return model
    case .editWithFee:
      let model = TransactionEditorModel.preview(.edit(PreviewData.id(411)))
      await model.load()
      model.addFee()
      if let fee = model.lines.last?.id, let index = model.lines.firstIndex(where: { $0.id == fee }) {
        model.lines[index].amountText = "0.99"
        model.lines[index].note = "Card fee"
      }
      return model
    }
  }

  static func date(_ day: String, hour: Int, minute: Int) -> Date {
    let d = Day(day)!
    return Calendar.current.date(
      from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hour, minute: minute))!
  }
}

/// Shows a scenario's sheet once its model has loaded.
struct EditorScenarioPreview: View {
  let scenario: EditorPreviewScenario
  @State private var model: TransactionEditorModel?

  var body: some View {
    Group {
      if let model {
        TransactionEditorSheet(model: model, onDone: { _ in })
      } else {
        ProgressView().frame(width: EditorMetrics.width, height: 400)
      }
    }
    .task { model = await scenario.makeModel() }
  }
}
