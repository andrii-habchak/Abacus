import AbacusDomain
import AbacusFeatures
import SwiftUI

/// "Archive “<account>”?" for an account whose balance is not zero (R-ACC-4, C29): the balance,
/// one checkbox, Cancel and Archive. An account outside a debt offers "Create a compensation
/// transaction"; an account in a debt offers "Forgive the debt (amount CUR)" with the R-DEBT-4
/// "Count as expense" option. Cancel changes nothing.
struct AccountArchiveSheetView: View {
  let model: AccountsModel
  let sheet: AccountArchiveSheet

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(sheet.title)
        .font(.system(size: 15, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      HStack {
        Text("Balance").foregroundStyle(.secondary)
        Spacer()
        Text(sheet.balanceText)
          .fontWeight(.semibold)
          .monospacedDigit()
          .foregroundStyle(sheet.balance.minorUnits < 0 ? ManagePalette.negative : Color.primary)
      }
      .padding(10)
      .background(ManagePalette.card, in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ManagePalette.border))
      Text(
        "Archived accounts are hidden from pickers and the dashboard and are not counted in net worth. Its history stays."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if sheet.isLinkedToDebt {
        debtOptions
      } else {
        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            "Create a compensation transaction",
            isOn: Binding(get: { sheet.createCompensation }, set: { model.setCreateCompensation($0) }))
          Text(model.compensationHint(sheet))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
        }
        .toggleStyle(.checkbox)
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Cancel", role: .cancel) { model.cancelArchiveSheet() }
          .keyboardShortcut(.cancelAction)
        Button("Archive") { Task { await model.confirmArchive() } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 4)
    }
    .font(.system(size: 13))
    .padding(20)
    .frame(width: 440)
  }

  @ViewBuilder private var debtOptions: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(
        model.forgiveTitle(sheet), isOn: Binding(get: { sheet.forgiveDebt }, set: { model.setForgiveDebt($0) })
      )
      .toggleStyle(.checkbox)
      Text(model.forgiveHint(sheet))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 20)
      if sheet.offersCountAsExpense {
        Toggle(
          "Count as expense",
          isOn: Binding(get: { sheet.countAsExpense }, set: { model.setCountAsExpense($0) })
        )
        .toggleStyle(.checkbox)
        .disabled(!sheet.forgiveDebt)
        .padding(.leading, 20)
        .padding(.top, 2)
      }
    }
  }
}
