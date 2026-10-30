import AbacusDomain
import AbacusFeatures
import AbacusImport
import SwiftUI

/// Column widths of the Transactions tab: Status 130, Date 86, then Description, Account,
/// Amount 110 and Category / action sharing the rest 1.8 : 1.1 : 1.5 (prototype grid).
struct ImportColumns {
  static let spacing: CGFloat = 10
  let status: CGFloat = 130
  let date: CGFloat = 86
  let amount: CGFloat = 110
  let description: CGFloat
  let account: CGFloat
  let category: CGFloat

  init(width: CGFloat) {
    let inner = max(0, width - 2 * ImportMetrics.horizontalPadding - 5 * Self.spacing - 130 - 86 - 110)
    let unit = max(inner, 420) / 4.4
    description = unit * 1.8
    account = unit * 1.1
    category = unit * 1.5
  }
}

/// Transactions tab: one line per source row with its status, category picker or duplicate
/// action and the note under it (R-IMP-1, R-IMP-4, R-IMP-8).
struct ImportRowsTab: View {
  let model: ImportWizardModel

  var body: some View {
    GeometryReader { proxy in
      let columns = ImportColumns(width: proxy.size.width)
      let rows = model.visibleRows
      VStack(spacing: 0) {
        header(columns)
        ImportRule(color: ImportPalette.softRule)
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(rows) { row in
              ImportRowView(model: model, row: row, columns: columns)
              ImportRule(color: ImportPalette.softRule)
            }
            Text(rows.count == model.rowItems.count
              ? "\(rows.count.formatted()) rows in this file."
              : "Showing \(rows.count.formatted()) of \(model.rowItems.count.formatted()) rows.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, ImportMetrics.horizontalPadding)
              .padding(.vertical, 10)
          }
        }
      }
    }
  }

  private func header(_ c: ImportColumns) -> some View {
    HStack(spacing: ImportColumns.spacing) {
      Text("Status").frame(width: c.status, alignment: .leading)
      Text("Date").frame(width: c.date, alignment: .leading)
      Text("Description").frame(width: c.description, alignment: .leading)
      Text("Account").frame(width: c.account, alignment: .leading)
      Text("Amount").frame(width: c.amount, alignment: .trailing)
      Text("Category / action").frame(width: c.category, alignment: .leading)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ImportRowView: View {
  let model: ImportWizardModel
  let row: ImportRowItem
  let columns: ImportColumns

  var body: some View {
    HStack(alignment: .center, spacing: ImportColumns.spacing) {
      ImportBadge(text: row.statusLabel, colors: ImportPalette.badge(row.status))
        .frame(width: columns.status, alignment: .leading)
      Text(row.date)
        .foregroundStyle(ImportPalette.label)
        .monospacedDigit()
        .frame(width: columns.date, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.payee).lineLimit(1)
        if !row.detail.isEmpty {
          Text(row.detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(width: columns.description, alignment: .leading)
      .help(row.detail)
      Text(row.account)
        .foregroundStyle(ImportPalette.label)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: columns.account, alignment: .leading)
        .help(row.account)
      Text(row.amount)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(row.isInflow ? ImportPalette.inflow : .primary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .opacity(row.isDimmed ? 0.5 : 1)
        .frame(width: columns.amount, alignment: .trailing)
      ImportRowActions(model: model, row: row)
        .frame(width: columns.category, alignment: .leading)
    }
    .font(.system(size: 13))
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.vertical, 7)
    .frame(minHeight: 40)
  }
}

/// Category picker, duplicate action, note and the rule switch of one row.
struct ImportRowActions: View {
  let model: ImportWizardModel
  let row: ImportRowItem

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let action = row.duplicateAction {
        Picker("Duplicate action", selection: duplicateBinding(action)) {
          Text("Skip (default)").tag(DuplicateAction.skip)
          Text("Import anyway").tag(DuplicateAction.importAnyway)
          Text("Link to existing").tag(DuplicateAction.link)
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 5).fill(ImportPalette.duplicateFill))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ImportPalette.duplicateBorder))
      }
      if case .picker(let selection, let options, let needsCategory) = row.category {
        Picker("Category", selection: categoryBinding(selection)) {
          ForEach(options) { option in
            Text(option.isChild ? "   \(option.label)" : option.label).tag(option.choice)
          }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(needsCategory ? ImportPalette.attentionBorder : .clear)
        )
      }
      if let debt = row.debt, row.status != .needsReview {
        // R-DEBT-10/12: the debt record this row becomes.
        Text(debt)
          .font(.system(size: 12))
          .lineLimit(1)
          .help(debt)
      }
      HStack(spacing: 6) {
        if let note = row.note {
          ImportNoteText(note: note)
        }
        if row.canRecordDebt {
          Button(row.debt == nil ? "Debt…" : "Edit…") {
            Task { await model.openDebt(forRow: row.id) }
          }
          .buttonStyle(.link)
          .font(.system(size: 11))
          .help("Record this payment as a debt record (lent, repaid, borrowed)")
          if row.debt != nil {
            Button("Not a debt") { model.removeDebt(forRow: row.id) }
              .buttonStyle(.link)
              .font(.system(size: 11))
          }
        }
        if let saves = row.savesRule {
          Button(saves ? "Don't save" : "Save as rule") {
            model.setSavesRule(!saves, forRow: row.id)
          }
          .buttonStyle(.link)
          .font(.system(size: 11))
        }
        if row.status == .needsReview {
          Button("Open") { model.tab = .review }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
      }
    }
  }

  private func categoryBinding(_ current: ImportCategoryChoice) -> Binding<ImportCategoryChoice> {
    Binding(get: { current }, set: { model.setCategory($0, forRow: row.id) })
  }

  private func duplicateBinding(_ current: DuplicateAction) -> Binding<DuplicateAction> {
    Binding(get: { current }, set: { model.setDuplicateAction($0, forRow: row.id) })
  }
}
