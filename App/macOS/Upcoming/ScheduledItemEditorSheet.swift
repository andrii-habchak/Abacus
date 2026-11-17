import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The scheduled item editor (prototype `N5-upcoming` sheet, R-REC-12, D55): type, description,
/// amount in the account currency, account (From / To for a transfer), category; Repeat
/// "Every [N] [unit]", Starts with "Last day of the month", Ends, the next five dates; match
/// tolerance, mode (remind only), note. Delete… and Pause/Resume at the left of the footer,
/// Save bottom-right (R-MGMT-10).
struct ScheduledItemEditorSheet: View {
  @Bindable var editor: ScheduledItemEditorModel
  @State private var confirmDelete = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(editor.title).font(.headline)
        if editor.suggestion != nil { UpcomingTextChip(text: "From a suggestion", tint: UpcomingPalette.positive) }
        if editor.isPausedByArchive { UpcomingTextChip(text: "Account archived", tint: .secondary) }
        else if editor.isPaused { UpcomingTextChip(text: "Paused", tint: .secondary) }
      }
      .padding([.horizontal, .top], 20)
      .padding(.bottom, 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if !editor.evidence.isEmpty {
            Text("Based on: " + editor.evidence.joined(separator: "  ·  "))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Picker("Type", selection: Binding(get: { editor.draft.type }, set: { editor.setType($0) })) {
            Text("Expense").tag(TxnType.expense)
            Text("Income").tag(TxnType.income)
            Text("Transfer").tag(TxnType.transfer)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
              label("Description")
              TextField("Merchant or payee", text: $editor.draft.payee)
            }
            GridRow {
              label("Amount")
              HStack(spacing: 8) {
                TextField("0.00", text: $editor.draft.amountText).frame(width: 130).monospacedDigit()
                Text(editor.currencyText).font(.caption).foregroundStyle(.secondary)
              }
            }
            GridRow {
              label(editor.draft.type == .transfer ? "From" : "Account")
              accountPicker(selection: $editor.draft.accountID, title: "Account")
            }
            if editor.draft.type == .transfer {
              GridRow {
                label("To")
                accountPicker(selection: $editor.draft.toAccountID, title: "To", excluding: editor.draft.accountID)
              }
              if editor.needsReceivedAmount {
                GridRow {
                  label("Received")
                  HStack(spacing: 8) {
                    TextField("0.00", text: $editor.draft.toAmountText).frame(width: 130).monospacedDigit()
                    Text(editor.toAccount?.currency.rawValue ?? "").font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            } else {
              GridRow {
                label("Category")
                Picker("Category", selection: $editor.draft.categoryID) {
                  Text("None").tag(AbacusDomain.Category.ID?.none)
                  ForEach(editor.categoryChoices) { category in
                    Text(categoryName(category)).tag(AbacusDomain.Category.ID?.some(category.id))
                  }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
              }
            }
            if !editor.events.isEmpty || editor.draft.eventID != nil {
              GridRow {
                label("Event")
                Picker("Event", selection: $editor.draft.eventID) {
                  Text("None").tag(Event.ID?.none)
                  ForEach(editor.events) { event in Text(event.name).tag(Event.ID?.some(event.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
              }
            }
            GridRow { Divider().gridCellColumns(2) }
            GridRow {
              label("Repeat")
              HStack(spacing: 8) {
                Text("Every")
                TextField("1", value: $editor.draft.interval, format: .number).frame(width: 56)
                Picker("Unit", selection: $editor.draft.unit) {
                  ForEach(ScheduleUnit.allCases, id: \.self) { unit in
                    Text(unit.rawValue + (editor.draft.interval == 1 ? "" : "s")).tag(unit)
                  }
                }
                .labelsHidden()
                .fixedSize()
              }
            }
            GridRow {
              label("Starts")
              HStack(spacing: 12) {
                UpcomingDayField(
                  title: "Starts", date: dayBinding($editor.draft.startDay),
                  text: editor.fieldDayText(editor.draft.startDay))
                if editor.draft.unit == .month {
                  Toggle("Last day of the month", isOn: $editor.draft.lastDayOfMonth)
                }
              }
            }
            GridRow {
              label("Ends")
              HStack(spacing: 8) {
                Picker("Ends", selection: $editor.draft.endKind) {
                  Text("Never").tag(ScheduleEndKind.never)
                  Text("On a day").tag(ScheduleEndKind.onDay)
                  Text("After a number of times").tag(ScheduleEndKind.afterCount)
                }
                .labelsHidden()
                .fixedSize()
                switch editor.draft.endKind {
                case .onDay:
                  UpcomingDayField(
                    title: "End day", date: dayBinding($editor.draft.endDay),
                    text: editor.fieldDayText(editor.draft.endDay))
                case .afterCount:
                  TextField("12", value: $editor.draft.endCount, format: .number).frame(width: 56)
                  Text("times")
                case .never:
                  EmptyView()
                }
              }
            }
            GridRow {
              label("Next dates")
              VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  let days = editor.nextDayTexts
                  if days.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                  }
                  ForEach(days, id: \.self) { day in
                    Text(day).font(.caption).monospacedDigit()
                      .fixedSize()
                      .padding(.horizontal, 6).padding(.vertical, 2)
                      .background(Capsule().fill(UpcomingPalette.evidence))
                  }
                }
                .accessibilityElement(children: .combine)
                if let hint = editor.monthEndHint {
                  Text(hint).font(.caption).foregroundStyle(.orange)
                }
              }
            }
            GridRow { Divider().gridCellColumns(2) }
            GridRow {
              label("Match tolerance")
              HStack(spacing: 6) {
                TextField("5", value: $editor.draft.tolerancePercent, format: .number).frame(width: 56)
                Text("%")
                Text("a bank row within ±3 days and this amount tolerance marks it paid")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            GridRow {
              label("Mode")
              Text("Remind me · the app never creates transactions by itself").font(.callout)
            }
            GridRow {
              label("Note")
              TextField("Optional", text: $editor.draft.note)
            }
          }
          .textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
      }
      // As tall as the fields (no empty band above the footer); scrolls only when they don't fit.
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: 640)
      .fixedSize(horizontal: false, vertical: true)
      if let message = editor.errorMessage ?? editor.issues.first.map(\.message) {
        Text(message).font(.caption)
          .foregroundStyle(editor.errorMessage == nil ? Color.secondary : UpcomingPalette.negative)
          .padding(.horizontal, 20)
          .padding(.top, 8)
      }
      HStack {
        if !editor.isNew {
          Button("Delete…", role: .destructive) { confirmDelete = true }
            .foregroundStyle(ManagePalette.destructive)
            .confirmationDialog("Delete “\(editor.draft.payee)”?", isPresented: $confirmDelete) {
              Button("Delete item", role: .destructive) { Task { await editor.delete() } }
            } message: {
              Text("Transactions that were matched to it are not touched.")
            }
          Button(editor.isPaused ? "Resume" : "Pause") { Task { await editor.togglePause() } }
            .disabled(editor.isWorking || (editor.isPaused && editor.isPausedByArchive))
            .help(editor.isPausedByArchive ? "Unarchive the account to resume" : "")
        }
        Spacer()
        Button("Cancel") { editor.cancel() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { Task { await editor.save() } }
          .keyboardShortcut(.defaultAction)
          .disabled(!editor.canSave)
      }
      .padding(20)
    }
    .frame(width: 660)
    .presentationSizing(.fitted)
  }

  private func label(_ text: String) -> some View {
    Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
  }

  private func categoryName(_ category: AbacusDomain.Category) -> String {
    guard let parent = category.parentID, let name = editor.categories.first(where: { $0.id == parent })?.name else {
      return category.name
    }
    return "\(name) › \(category.name)"
  }

  private func accountPicker(
    selection: Binding<Account.ID?>, title: String, excluding: Account.ID? = nil
  ) -> some View {
    Picker(title, selection: selection) {
      if selection.wrappedValue == nil { Text("Choose…").tag(Account.ID?.none) }
      ForEach(editor.accountChoices.filter { $0.id != excluding }) { account in
        Text("\(account.name) (\(account.currency.rawValue))").tag(Account.ID?.some(account.id))
      }
    }
    .labelsHidden()
    .frame(maxWidth: 280, alignment: .leading)
  }

  /// A `Day` edited with a date picker (local calendar, noon to stay clear of DST edges).
  private func dayBinding(_ day: Binding<Day>) -> Binding<Date> {
    Binding(
      get: { day.wrappedValue.date() },
      set: { day.wrappedValue = Day($0) })
  }
}

/// A day as text in the app's style ("Sat, 5 Dec 2026") with a calendar to pick it (QA-N2 L5:
/// the stepper field showed "5/ 1/2026").
private struct UpcomingDayField: View {
  let title: String
  @Binding var date: Date
  let text: String
  @State private var showsCalendar = false

  var body: some View {
    Button {
      showsCalendar.toggle()
    } label: {
      HStack(spacing: 6) {
        Text(text).monospacedDigit()
        Image(systemName: "calendar").foregroundStyle(.secondary)
      }
    }
    .accessibilityLabel("\(title): \(text)")
    .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
      DatePicker(title, selection: $date, displayedComponents: .date)
        .labelsHidden()
        .datePickerStyle(.graphical)
        .padding(12)
    }
  }
}
