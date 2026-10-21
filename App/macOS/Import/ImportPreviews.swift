import AbacusDomain
import AbacusFeatures
import AbacusImport
import SwiftUI

/// States of the import screen on the synthetic preview world (`ImportWizardDependencies.preview()`
/// and `ImportSamples`), for `#Preview`s and screenshots. Never the app database.
enum ImportScenario: String, CaseIterable {
  case chooseFile
  case pkoTransactions
  case pkoAccounts
  case pkoNeedsReview
  case pkoChooseAccount
  case saldoTransactions
  case saldoAccounts
  case saldoEvents
  case saldoNeedsReview
  case done
  case history

  @MainActor
  func model() async throws -> ImportWizardModel {
    if self == .pkoChooseAccount {
      // A database with no remembered statement account.
      let model = ImportWizardModel(dependencies: .live(database: try PreviewData.database()))
      await model.load()
      await model.open(data: ImportSamples.pko, fileName: ImportSamples.pkoFileName)
      return model
    }
    let model = ImportWizardModel(dependencies: try await .preview())
    await model.load()
    switch self {
    case .chooseFile, .pkoChooseAccount:
      break
    case .pkoTransactions, .pkoAccounts, .pkoNeedsReview, .done, .history:
      await model.open(data: ImportSamples.pko, fileName: ImportSamples.pkoFileName)
      if let cafe = model.rowItems.first(where: { $0.payee == "KAWIARNIA RELAKS" }) {
        model.setCategory(.existing(PreviewData.id(203)), forRow: cafe.id)
      }
      switch self {
      case .pkoAccounts: model.tab = .mapping
      case .pkoNeedsReview: model.selectFilter(.needsReview)
      case .done, .history:
        model.acceptSuggestions()
        await model.commit()
        if self == .history { model.isHistoryShown = true }
      default: break
      }
    case .saldoTransactions, .saldoAccounts, .saldoEvents, .saldoNeedsReview:
      await model.open(data: ImportSamples.saldo, fileName: ImportSamples.saldoFileName)
      model.setEvent(tag: "Trip 2025", selected: true)
      if let half = model.reviewItems.first(where: { $0.title.hasSuffix("To the USD card") }) {
        model.selectReviewOption(.pair, forRow: half.id)
      }
      if let sent = model.reviewItems.first(where: { $0.title.hasSuffix("Money sent") }) {
        model.selectReviewOption(.record(.expense), forRow: sent.id)
      }
      switch self {
      case .saldoAccounts: model.tab = .mapping
      case .saldoEvents: model.tab = .events
      case .saldoNeedsReview: model.tab = .review
      default: break
      }
    }
    return model
  }
}

/// Loads a scenario's model, then shows the import screen.
struct ImportScenarioPreview: View {
  let scenario: ImportScenario
  @State private var model: ImportWizardModel?

  var body: some View {
    Group {
      if let model {
        ImportView(model: model)
      } else {
        ProgressView()
      }
    }
    .frame(width: 1060, height: 760)
    .task { model = try? await scenario.model() }
  }
}

#Preview("Choose file") {
  ImportScenarioPreview(scenario: .chooseFile)
}

#Preview("PKO · transactions") {
  ImportScenarioPreview(scenario: .pkoTransactions)
}

#Preview("PKO · accounts") {
  ImportScenarioPreview(scenario: .pkoAccounts)
}

#Preview("PKO · needs review") {
  ImportScenarioPreview(scenario: .pkoNeedsReview)
}

#Preview("PKO · choose account") {
  ImportScenarioPreview(scenario: .pkoChooseAccount)
}

#Preview("Saldo · transactions") {
  ImportScenarioPreview(scenario: .saldoTransactions)
}

#Preview("Saldo · accounts & categories") {
  ImportScenarioPreview(scenario: .saldoAccounts)
}

#Preview("Saldo · events from tags") {
  ImportScenarioPreview(scenario: .saldoEvents)
}

#Preview("Saldo · needs review") {
  ImportScenarioPreview(scenario: .saldoNeedsReview)
}

#Preview("Done") {
  ImportScenarioPreview(scenario: .done)
}

#Preview("History") {
  ImportScenarioPreview(scenario: .history)
}

#Preview("PKO · transactions · dark") {
  ImportScenarioPreview(scenario: .pkoTransactions)
    .preferredColorScheme(.dark)
}
