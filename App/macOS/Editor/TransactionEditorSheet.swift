import AbacusDomain
import AbacusFeatures
import SwiftUI

/// Layout of the editor sheet: header (title, type, amount, refund, defaults hint), the form,
/// fee / split lines with the account effect, and the footer (Delete… / Duplicate in edit
/// mode, ⏎ Save, ⎋ Cancel). R-EDIT-1…5, R-TX-1…7, R-CUR-4, R-EVT-2.
struct TransactionEditorSheet: View {
  @Bindable var model: TransactionEditorModel
  let onDone: (TransactionEditorResult) -> Void

  @State private var contentHeight: CGFloat = 0
  @State private var confirmingDelete = false

  var body: some View {
    VStack(spacing: 0) {
      EditorHeader(model: model)
        .background(EditorPalette.header)
      EditorRule()
      ScrollView {
        form
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
      }
      .frame(height: min(max(contentHeight, 120), EditorMetrics.maxBodyHeight))
      .background(EditorPalette.body)
      EditorRule()
      footer
        .background(EditorPalette.header)
    }
    .frame(width: EditorMetrics.width)
    .background(EditorPalette.body)
    .font(.system(size: 13))
    .disabled(!model.isLoaded && model.errorMessage == nil)
    .sheet(
      isPresented: Binding(
        get: { model.refundPicker != nil },
        set: { if !$0 { model.cancelRefundPicker() } })
    ) {
      if let picker = model.refundPicker {
        RefundPickerSheet(
          model: picker, onChoose: { model.chooseRefundOriginal($0) }, onCancel: { model.cancelRefundPicker() })
      }
    }
    .alert("Delete this transaction?", isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) {
        Task {
          if let result = await model.delete() { onDone(result) }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(model.deleteMessage)
    }
  }

  private var form: some View {
    VStack(spacing: 0) {
      if model.isTransfer {
        EditorTransferSection(model: model)
      } else {
        EditorAccountSection(model: model)
      }
      EditorRule()
      EditorDetailsSection(model: model)
      EditorRule()
      EditorLinesSection(model: model)
    }
    .padding(.horizontal, 20)
    .padding(.top, 6)
    .padding(.bottom, 14)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if !model.isNew {
        Button("Delete…") { confirmingDelete = true }
          .buttonStyle(EditorFooterButtonStyle(role: .destructive))
        Button("Duplicate") { model.duplicate() }
          .buttonStyle(EditorFooterButtonStyle())
      }
      if let error = model.errorMessage {
        Text(error)
          .font(.system(size: 11))
          .foregroundStyle(EditorPalette.error)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      Text("⏎ Save · ⎋ Cancel")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Button("Cancel") { onDone(.cancelled) }
        .keyboardShortcut(.cancelAction)
        .controlSize(.large)
      Button("Save") {
        Task {
          if let result = await model.save() { onDone(result) }
        }
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(!model.canSave)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }
}

/// Bordered footer button; red for Delete….
struct EditorFooterButtonStyle: ButtonStyle {
  var role: ButtonRole?

  func makeBody(configuration: Configuration) -> some View {
    let destructive = role == .destructive
    configuration.label
      .foregroundStyle(destructive ? EditorPalette.error : Color.primary)
      .padding(.horizontal, 12)
      .frame(minHeight: 28)
      .background(RoundedRectangle(cornerRadius: 6).fill(EditorPalette.lineBackground))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(destructive ? EditorPalette.deleteBorder : EditorPalette.rule)
      )
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(Rectangle())
  }
}

// MARK: - Header

/// Title (+ source when editing), Expense / Income / Transfer, the big signed amount with the
/// currency picker, Refund / Reversal, and the last-used defaults hint.
struct EditorHeader: View {
  @Bindable var model: TransactionEditorModel

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 10) {
        Text(model.title)
          .font(.system(size: 15, weight: .semibold))
        Spacer(minLength: 0)
        if let source = model.sourceText {
          Text(source)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      Picker("Type", selection: $model.type) {
        Text("Expense").tag(TxnType.expense)
        Text("Income").tag(TxnType.income)
        Text("Transfer").tag(TxnType.transfer)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      amount
      if model.showsRefund {
        Toggle(model.refundLabel, isOn: $model.isRefund)
          .toggleStyle(.checkbox)
          .font(.system(size: 12))
      }
      if model.offersRefundOf {
        // R-TX-4 (C30): the expense this refund returns money for; its category follows it.
        HStack(spacing: 8) {
          Text("Refund of").foregroundStyle(.secondary)
          Text(model.refundOfText)
            .fontWeight(model.refundOfID == nil ? .regular : .medium)
            .foregroundStyle(model.refundOfID == nil ? Color.secondary : Color.primary)
            .lineLimit(1)
          Button(model.refundOfID == nil ? "Choose…" : "Change…") {
            Task { await model.beginChooseRefundOriginal() }
          }
          if model.refundOfID != nil {
            Button("Remove") { model.clearRefundOriginal() }
          }
        }
        .font(.system(size: 12))
        .controlSize(.small)
      }
      if let hint = model.defaultsHint {
        EditorHint(text: hint)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 18)
    .padding(.bottom, 14)
  }

  private var amount: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(model.sign)
        .font(.system(size: model.isTransfer ? 22 : 28, weight: model.isTransfer ? .regular : .semibold))
        .foregroundStyle(model.isTransfer ? Color.secondary : model.isInflow ? EditorPalette.inflow : Color.primary)
      // Sized to the typed text so the sign stays next to the number.
      Text(model.amountText.isEmpty ? "0.00" : model.amountText)
        .font(.system(size: 34, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(minWidth: 90)
        .hidden()
        .overlay {
          TextField(model.amountLabel, text: $model.amountText, prompt: Text("0.00"))
            .textFieldStyle(.plain)
            .font(.system(size: 34, weight: .semibold))
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .accessibilityLabel(model.amountLabel)
        }
      if model.isTransfer {
        Text(model.amountCode)
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(.secondary)
      } else {
        Picker("Currency", selection: $model.currencyCode) {
          ForEach(model.currencyOptions, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .font(.system(size: 15, weight: .medium))
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      }
    }
  }
}

// MARK: - Sections

/// Expense / income: Account, Charged to account (foreign currency), Category + suggestion.
struct EditorAccountSection: View {
  @Bindable var model: TransactionEditorModel

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
      GridRow {
        EditorLabel("Account")
        EditorAccountPicker(title: "Account", selection: $model.accountID, sections: model.accountSections)
      }
      if model.isForeign {
        GridRow(alignment: .firstTextBaseline) {
          EditorLabel("Charged to account")
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
              EditorAmountField(title: "Charged to account", text: $model.chargedText)
              Text(model.account?.currency.rawValue ?? "")
                .foregroundStyle(.secondary)
            }
            EditorHint(text: model.chargedHint)
          }
        }
      }
      GridRow(alignment: .firstTextBaseline) {
        EditorLabel("Category")
        VStack(alignment: .leading, spacing: 4) {
          Picker("Category", selection: $model.categoryID) {
            if model.categoryID == nil {
              Text("Choose a category").tag(AbacusDomain.Category.ID?.none)
            }
            ForEach(model.categoryOptions) { option in
              Text(option.isChild ? "\u{2003}" + option.name : option.name)
                .tag(Optional(option.id))
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
          if let suggestion = model.suggestionText {
            EditorHint(text: suggestion, color: EditorPalette.suggestion)
          }
        }
      }
    }
    .padding(.vertical, 12)
  }
}

/// Transfer: From, To (error when equal), Amount received + implied rate across currencies.
struct EditorTransferSection: View {
  @Bindable var model: TransactionEditorModel

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
      GridRow {
        EditorLabel("From")
        EditorAccountPicker(title: "From", selection: $model.fromID, sections: model.accountSections)
      }
      GridRow {
        EditorLabel("To")
        EditorAccountPicker(title: "To", selection: $model.toID, sections: model.accountSections)
      }
      if model.sameAccounts {
        GridRow {
          Color.clear.frame(width: EditorMetrics.labelColumn, height: 1)
          Text("From and To must be different accounts.")
            .font(.system(size: 12))
            .foregroundStyle(EditorPalette.error)
        }
      }
      if model.crossCurrency {
        GridRow {
          EditorLabel("Amount received")
          HStack(spacing: 8) {
            EditorAmountField(title: "Amount received", text: $model.toAmountText)
            Text(model.toAccount?.currency.rawValue ?? "")
              .foregroundStyle(.secondary)
          }
        }
        if let rate = model.impliedRateText {
          GridRow {
            Color.clear.frame(width: EditorMetrics.labelColumn, height: 1)
            Text(rate)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(.vertical, 12)
  }
}

/// Description, Date and time, Event (+ pre-selection hint), Note.
struct EditorDetailsSection: View {
  @Bindable var model: TransactionEditorModel

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
      GridRow {
        EditorLabel("Description")
        TextField("Description", text: $model.payee, prompt: Text("Merchant or payee"))
          .labelsHidden()
      }
      GridRow {
        EditorLabel("Date and time")
        HStack(spacing: 8) {
          DatePicker("Date", selection: $model.occurredAt, displayedComponents: .date)
          DatePicker("Time", selection: $model.occurredAt, displayedComponents: .hourAndMinute)
        }
        .labelsHidden()
        .datePickerStyle(.field)
      }
      GridRow(alignment: .firstTextBaseline) {
        EditorLabel("Event")
        VStack(alignment: .leading, spacing: 4) {
          Picker("Event", selection: $model.eventID) {
            Text("None").tag(Event.ID?.none)
            ForEach(model.eventOptions) { event in
              Text(model.eventLabel(event)).tag(Optional(event.id))
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
          if let hint = model.eventHint {
            EditorHint(text: hint, color: EditorPalette.event)
          }
        }
      }
      GridRow(alignment: .top) {
        EditorLabel("Note")
          .padding(.top, 3)
        TextField("Note", text: $model.note, prompt: Text("Optional"), axis: .vertical)
          .labelsHidden()
          .lineLimit(2...5)
      }
    }
    .padding(.vertical, 12)
  }
}

/// An account menu: "Monobank Black · UAH" (R-ACC-1) A–Z under its group (R-MGMT-8);
/// archived accounts are hidden.
struct EditorAccountPicker: View {
  let title: String
  @Binding var selection: Account.ID?
  let sections: [AccountPickerSection]

  var body: some View {
    Picker(title, selection: $selection) {
      if selection == nil {
        Text("Choose an account").tag(Account.ID?.none)
      }
      AccountPickerItems(sections: sections) { account in
        Text(EditorReference.accountLabel(account)).tag(Optional(account.id))
      }
    }
    .labelsHidden()
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A right-aligned amount field, 140 pt wide.
struct EditorAmountField: View {
  let title: String
  @Binding var text: String
  var width: CGFloat = 140

  var body: some View {
    TextField(title, text: $text, prompt: Text("0.00"))
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
      .frame(width: width)
  }
}
