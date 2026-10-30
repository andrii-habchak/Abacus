import AbacusDomain
import AbacusFeatures
import SwiftUI

/// C38: "Looks like the other side of the transfer on …" with Accept / Not this; once accepted
/// "Completes the transfer of …" with Undo; after "Not this" a quiet Undo.
struct ImportEstimateControls: View {
  let model: ImportWizardModel
  let rowID: String
  let estimate: ImportEstimateItem

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      switch estimate.state {
      case .offered, .accepted:
        Text(estimate.text)
          .font(.system(size: 11))
          .foregroundStyle(estimate.state == .accepted ? ImportPalette.inflow : .secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .help(estimate.text)
        HStack(spacing: 8) {
          if estimate.state == .offered {
            Button("Accept") { model.acceptEstimateOffer(forRow: rowID) }
            Button("Not this") { model.declineEstimate(forRow: rowID) }
          } else {
            Button("Undo") { model.resetEstimate(forRow: rowID) }
          }
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
      case .declined:
        HStack(spacing: 6) {
          Text(estimate.text).font(.system(size: 11)).foregroundStyle(.secondary)
          Button("Undo") { model.resetEstimate(forRow: rowID) }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
      }
    }
  }
}

/// C38: what the row's transfer takes as its other side, with "Change…".
struct ImportCounterpartLine: View {
  let model: ImportWizardModel
  let rowID: String
  let counterpart: ImportCounterpartItem

  var body: some View {
    HStack(spacing: 6) {
      Text(counterpart.text)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .help(counterpart.text)
      Button("Change…") { model.beginCounterpart(forRow: rowID, to: counterpart.accountID) }
        .buttonStyle(.link)
        .font(.system(size: 11))
    }
  }
}

/// "Find the other side…" (C38): the transaction on the other account that is the other side of the
/// row's transfer, or, when the other statement is not imported yet, the amount typed by hand or
/// estimated at the day's rate.
struct ImportCounterpartSheet: View {
  let model: ImportWizardModel
  @Bindable var picker: TransferCounterpartModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(picker.title).font(.headline)
        Text(picker.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
      }
      Text("Pick the transaction you imported from the other account's statement. It becomes this transfer, with both real amounts.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("Search description, note or amount", text: $picker.search)
        .textFieldStyle(.roundedBorder)
      list
      Divider()
      noCounterpartYet
      if let error = picker.errorMessage {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel") { model.cancelCounterpart() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 560, height: 600)
    .task(id: picker.search) {
      // A short pause so typing does not query on every keystroke.
      try? await Task.sleep(for: .milliseconds(150))
      if Task.isCancelled { return }
      await picker.load()
    }
  }

  @ViewBuilder
  private var list: some View {
    if picker.options.isEmpty {
      VStack {
        Spacer()
        Text(picker.isLoading ? "Searching…" : "No matching transaction within 5 days. Type to search further back.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List(picker.options) { option in
        Button {
          model.chooseCounterpart(option)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text(option.title).fontWeight(.medium).lineLimit(1)
              Text(option.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(option.isUsable ? Color.secondary : Color.red)
                .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
              Text(option.amountText).monospacedDigit().fontWeight(.semibold)
              Text(option.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
          }
          .contentShape(Rectangle())
          .opacity(option.isUsable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(option.refusal ?? "Use this transaction as the other side of the transfer")
      }
      .listStyle(.bordered)
    }
  }

  private var noCounterpartYet: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("The other statement is not imported yet").font(.system(size: 12, weight: .semibold))
      HStack(spacing: 8) {
        TextField("Amount received in \(picker.currencyCode)", text: $picker.manualText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 200)
          .onSubmit { model.useManualCounterpart() }
        Button("Use this amount") { model.useManualCounterpart() }
          .disabled(picker.manualAmountMinor == nil)
      }
      HStack(spacing: 8) {
        Button("Estimate at the NBU rate") { model.useEstimatedCounterpart() }
          .disabled(picker.estimate == nil)
        if let estimate = picker.estimate {
          Text("\(estimate.amountText) · \(estimate.rateText)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          Text("No exchange rate is known for this day.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      Text("An estimated transfer is marked until a later import brings the real figure.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }
}
