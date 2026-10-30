import AbacusDomain
import AbacusFeatures
import SwiftUI

/// "Archive the related accounts?" (R-DEBT-5, R-DEBT-17, C29): shown when a debt with
/// non-archived linked accounts is marked settled. One checkbox per account (virtual ticked,
/// external not), Cancel and Settle. Chosen accounts are archived as they are, without a
/// compensation; reopening the debt later does not unarchive them.
struct DebtSettlePromptSheet: View {
  let model: DebtsModel
  let prompt: DebtsModel.SettlePrompt

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Archive the related accounts?")
        .font(.system(size: 15, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(
        "\(prompt.personName) is settled up. Tick the accounts to archive with it; they are archived as they are, "
          + "without a compensation. Reopening the debt later does not unarchive them."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(prompt.accounts) { account in
          Toggle(
            isOn: Binding(get: { account.archive }, set: { model.setArchiveOnSettle(account.id, $0) })
          ) {
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 1) {
                Text(account.name)
                Text(account.roleText).font(.system(size: 11)).foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
              Text(account.balanceText).monospacedDigit().foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.checkbox)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ManagePalette.card, in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ManagePalette.border))
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Cancel", role: .cancel) { model.cancelSettlePrompt() }
          .keyboardShortcut(.cancelAction)
        Button("Settle") { Task { await model.confirmSettle() } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 4)
    }
    .font(.system(size: 13))
    .padding(20)
    .frame(width: 440)
  }
}

extension View {
  /// The settle prompt as a sheet on whatever view owns the debts menu.
  func settlePromptSheet(model: DebtsModel) -> some View {
    sheet(
      item: Binding(
        get: { model.settlePrompt }, set: { if $0 == nil, model.settlePrompt != nil { model.cancelSettlePrompt() } })
    ) { prompt in
      DebtSettlePromptSheet(model: model, prompt: prompt)
    }
  }
}
