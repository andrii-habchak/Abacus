import AbacusFeatures
import SwiftUI

#Preview("New (empty)") {
  TransactionEditor(mode: .new, dependencies: .preview(), onDone: { _ in })
}

#Preview("New expense") {
  EditorScenarioPreview(scenario: .newExpense)
}

#Preview("Foreign currency") {
  EditorScenarioPreview(scenario: .foreignExpense)
}

#Preview("Transfer") {
  EditorScenarioPreview(scenario: .transfer)
}

#Preview("Edit with a fee") {
  EditorScenarioPreview(scenario: .editWithFee)
}

#Preview("Foreign currency · dark") {
  EditorScenarioPreview(scenario: .foreignExpense)
    .preferredColorScheme(.dark)
}
