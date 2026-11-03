import AbacusDomain
import AbacusFeatures
import AbacusImport
import AppKit
import SwiftUI

// N6 (R-CLR-8, R-CLR-9): the "Pending payments" and "Balance gaps" lists of the Needs review tab.

/// Pending holds the file should have settled and did not: one decision each, with bulk actions
/// (click selects, ⌘ click adds or removes, ⇧ click selects a range, like the rows).
struct ImportStaleList: View {
  @Bindable var model: ImportWizardModel

  var body: some View {
    let items = model.staleItems
    VStack(alignment: .leading, spacing: 12) {
      if items.isEmpty {
        Text("No pending payments are missing from this file.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
      } else {
        bar(items)
        Text(
          "Holds from earlier imports that this file should have settled (their value day is at least \(StaleHolds.staleDays) days before its last booked day) and did not. Click selects one, ⌘ click adds or removes one, ⇧ click selects a range. Each needs a decision before you import; the count is kept on the import record."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        ForEach(items) { item in
          ImportStaleCard(model: model, item: item)
        }
      }
    }
    .frame(maxWidth: 900, alignment: .leading)
  }

  private func bar(_ items: [ImportStaleItem]) -> some View {
    let selected = model.selectedStaleIDs
    return HStack(spacing: 8) {
      Toggle(
        "Select all",
        isOn: Binding(
          get: { selected.count == items.count },
          set: { $0 ? model.selectAll() : model.clearSelection() })
      )
      .toggleStyle(.checkbox)
      Spacer(minLength: 8)
      Text(selected.isEmpty ? "None selected" : "\(selected.count.formatted()) selected")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      ForEach([ImportStaleChoice.keep, .markSettled, .delete], id: \.self) { choice in
        Button(choice.label) { model.setStale(choice, ids: selected) }
          .disabled(selected.isEmpty)
      }
      Button("Keep all") { model.keepAllStale() }
    }
  }
}

private struct ImportStaleCard: View {
  @Bindable var model: ImportWizardModel
  let item: ImportStaleItem

  private var id: Txn.ID { UUID(uuidString: item.id) ?? UUID() }
  private var isSelected: Bool { model.selection.contains(item.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Toggle(
          "Select \(item.payee)",
          isOn: Binding(
            get: { isSelected },
            set: { _ in model.select(item.id, mode: .toggle) })
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
        VStack(alignment: .leading, spacing: 2) {
          Text("\(item.payee) · \(item.amount)")
            .font(.system(size: 13, weight: .semibold))
          Text("Pending hold · value day \(item.valueDay) · imported earlier, source PKO")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Text("Pending payment not in the bank file")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(ImportPalette.badge(.possibleDuplicate).text)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Capsule().fill(ImportPalette.badge(.possibleDuplicate).fill))
      }
      Text(item.explanation)
        .font(.system(size: 12))
        .foregroundStyle(ImportPalette.label)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 14) {
        ForEach(ImportStaleChoice.allCases, id: \.self) { choice in
          Button {
            model.setStale(choice, ids: [id])
          } label: {
            HStack(spacing: 5) {
              Image(systemName: item.choice == choice ? "largecircle.fill.circle" : "circle")
              Text(choice.label)
            }
          }
          .buttonStyle(.plain)
          .font(.system(size: 13))
        }
      }
      if item.choice == .edit { editor }
      Text(item.outcome)
        .font(.system(size: 11))
        .foregroundStyle(item.choice == nil ? ImportPalette.attention : (item.choice == .delete ? ImportPalette.attention : ImportPalette.inflow))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(RoundedRectangle(cornerRadius: 10).fill(ImportPalette.duplicateFill))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(isSelected ? ImportPalette.accent : ImportPalette.duplicateBorder, lineWidth: isSelected ? 2 : 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 10))
    .onTapGesture { importSelect(model, item.id) }
  }

  private var editor: some View {
    HStack(alignment: .bottom, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Amount").font(.system(size: 11)).foregroundStyle(.secondary)
        TextField(
          "Amount",
          text: Binding(
            get: { item.draft.amountText },
            set: { value in model.updateStaleEdit(id) { $0.amountText = value } })
        )
        .multilineTextAlignment(.trailing)
        .frame(width: 100)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text("Purchase day").font(.system(size: 11)).foregroundStyle(.secondary)
        DatePicker(
          "Purchase day",
          selection: Binding(
            get: { item.draft.day },
            set: { value in model.updateStaleEdit(id) { $0.day = value } }),
          displayedComponents: .date
        )
        .labelsHidden()
      }
      Toggle(
        "Still pending",
        isOn: Binding(
          get: { item.draft.stillPending },
          set: { value in model.updateStaleEdit(id) { $0.stillPending = value } })
      )
      .toggleStyle(.checkbox)
      Text("Stays uncleared: the bank file does not show it.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(ImportPalette.surface))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ImportPalette.border))
  }
}

/// Balance gaps: each of the two rows next to a gap is Left (imported as the file says) or Removed.
struct ImportGapList: View {
  @Bindable var model: ImportWizardModel

  var body: some View {
    let gaps = model.gapItems
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(gaps.isEmpty ? "Balance continuity: no gaps" : "Balance continuity: \(gaps.count.formatted()) gap\(gaps.count == 1 ? "" : "s")")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        if !gaps.isEmpty { Button("Leave all") { model.leaveAllGaps() } }
      }
      ForEach(gaps) { gap in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(gap.title)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(ImportPalette.attention)
            Spacer()
            Text("Balance gap \(gap.missing)")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(ImportPalette.attention)
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(Capsule().fill(ImportPalette.badge(.needsReview).fill))
          }
          Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
              header("Row")
              header("Amount")
              header("Balance after")
              header("Starts from")
              header("Action")
            }
            gapRow(gap.before)
            gapRow(gap.after)
          }
          Text(gap.advice)
            .font(.system(size: 12))
            .foregroundStyle(ImportPalette.label)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(ImportPalette.reviewFill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ImportPalette.attentionBorder))
      }
      if let note = model.startCheckNote {
        Text(note.text)
          .font(.system(size: 12))
          .foregroundStyle(ImportPalette.tone(note.tone))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: 900, alignment: .leading)
  }

  private func header(_ title: String) -> some View {
    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
  }

  private func gapRow(_ row: ImportGapRowItem) -> some View {
    GridRow {
      Text("\(row.day) \(row.payee)").lineLimit(1)
      Text(row.amount).monospacedDigit()
      Text(row.balanceAfter).monospacedDigit()
      Text(row.startsFrom).monospacedDigit()
      Picker(
        "Action",
        selection: Binding(
          get: { row.isRemoved },
          set: { model.setGapRow(row.id, removed: $0) })
      ) {
        Text("Leave (import)").tag(false)
        Text("Remove (do not import)").tag(true)
      }
      .labelsHidden()
      .fixedSize()
    }
    .font(.system(size: 12))
  }
}
