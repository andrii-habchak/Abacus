import AbacusDomain
import AbacusFeatures
import AbacusImport
import SwiftUI

/// C44: History → "Move to another account…". The batch's transactions in the review's row list
/// (same columns, header sort, click / Cmd / Shift selection; selected rows move), the account
/// they move to (searchable picker, the batch's currency only), what the move does, and
/// "Move N transactions".
struct ImportMoveSheet: View {
  let model: ImportWizardModel
  @Bindable var sheet: ImportMoveModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(sheet.title).font(.headline).lineLimit(1)
          Text(sheet.subtitle)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 10) {
          Text("Move to").font(.system(size: 13, weight: .semibold))
          AccountPicker(
            items: sheet.targetItems, selection: $sheet.targetAccountID, placeholder: "Choose account…", width: 300,
            accessibilityTitle: "Move to account")
          Spacer()
          Text("Click, ⌘-click or ⇧-click rows; selected rows move.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
          Button("Select all") { sheet.selectAll() }
            .controlSize(.small)
          Button("Select none") { sheet.selectNone() }
            .controlSize(.small)
        }
      }
      .padding(.horizontal, ImportMetrics.horizontalPadding)
      .padding(.top, 18)
      .padding(.bottom, 10)

      GeometryReader { proxy in
        let columns = ImportColumns(width: proxy.size.width)
        let rows = sheet.visibleRows
        VStack(spacing: 0) {
          ImportRule()
          ImportRowsHeader(columns: columns, model: sheet)
          ImportRule(color: ImportPalette.softRule)
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(rows) { row in
                ImportMoveRowView(sheet: sheet, row: row, columns: columns, isSelected: sheet.selection.contains(row.id))
                ImportRule(color: ImportPalette.softRule)
              }
            }
          }
          ImportRule()
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(sheet.summaryLines, id: \.self) { line in
            Text(line)
              .font(.system(size: 12))
              .foregroundStyle(ImportPalette.label)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if let error = sheet.errorMessage {
          Text(error)
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
          Spacer()
          Button("Cancel") { model.cancelMove() }
            .keyboardShortcut(.cancelAction)
          Button(sheet.moveButtonTitle) { model.startMove() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!sheet.canMove)
        }
      }
      .padding(.horizontal, ImportMetrics.horizontalPadding)
      .padding(.vertical, 14)
    }
    .frame(minWidth: 960, idealWidth: 1040, minHeight: 600, idealHeight: 680)
    .background(ImportPalette.surface)
    .disabled(sheet.isMoving)
  }
}

/// One row of the move list: the review's cells, then the category and why the row moves or
/// stays.
struct ImportMoveRowView: View {
  let sheet: ImportMoveModel
  let row: ImportRowItem
  let columns: ImportColumns
  var isSelected = false

  var body: some View {
    HStack(alignment: .center, spacing: ImportColumns.spacing) {
      ImportRowCells(row: row, columns: columns)
      VStack(alignment: .leading, spacing: 2) {
        Text(sheet.categoryName(ofRow: row.id) ?? "—")
          .lineLimit(1)
          .foregroundStyle(sheet.categoryName(ofRow: row.id) == nil ? .secondary : .primary)
        if let note = row.note {
          ImportNoteText(note: note)
            .help(note.text)
        }
      }
      .frame(width: columns.category, alignment: .leading)
    }
    .font(.system(size: 13))
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.vertical, 7)
    .frame(minHeight: 40)
    .background(isSelected ? ImportPalette.accentFill : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { importSelect(sheet, row.id) }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
