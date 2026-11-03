import AbacusDomain
import AbacusFeatures
import SwiftUI

/// N6 (R-CLR-5, R-CLR-6): Reconcile an account with its statement (or counted cash): a setup step,
/// then the working screen with the three figures, the rows to check, and the ways to make the
/// difference zero (tick, add, edit, delete, mark settled, correct). Nothing is saved until Finish.
struct ReconcileView: View {
  @Bindable var model: ReconcileModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      switch model.phase {
      case .loading:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ContentUnavailableView("Can't reconcile", systemImage: "exclamationmark.triangle", description: Text(message))
      case .setup:
        ReconcileSetup(model: model)
      case .working:
        ReconcileWorking(model: model)
      }
    }
    // An explicit ideal size, like Import's: without it the window follows the content's ideal height.
    .frame(minWidth: 0, idealWidth: 900, maxWidth: .infinity, minHeight: 0, idealHeight: 600, maxHeight: .infinity)
    .navigationTitle(model.title)
    #if DEBUG
      .task { await debugDrive() }
    #endif
    .alert("Reconcile", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  #if DEBUG
    /// UI checks (in-app snapshot): `-AbacusReconcileStart YES` leaves the setup step (with
    /// `-AbacusReconcileDay <YYYY-MM-DD>` and `-AbacusReconcileClosing <text>` when given),
    /// `-AbacusReconcileTickAll YES` ticks every row to check, `-AbacusReconcileShowCleared YES`
    /// opens "Already cleared".
    private func debugDrive() async {
      let defaults = UserDefaults.standard
      FileHandle.standardError.write(Data("RECONCILE appeared phase=\(model.phase)\n".utf8))
      guard defaults.bool(forKey: "AbacusReconcileStart") else { return }
      for _ in 0..<50 where model.phase == .loading { try? await Task.sleep(for: .milliseconds(100)) }
      if let day = defaults.string(forKey: "AbacusReconcileDay") {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: day) { model.statementDay = date }
      }
      if let closing = defaults.string(forKey: "AbacusReconcileClosing") { model.closingText = closing }
      model.start()
      if defaults.bool(forKey: "AbacusReconcileTickAll") { model.tickAll() }
      if defaults.bool(forKey: "AbacusReconcileShowCleared") { model.showCleared = true }
      FileHandle.standardError.write(Data("RECONCILE driven phase=\(model.phase)\n".utf8))
    }
  #endif

  private var header: some View {
    HStack(spacing: 12) {
      Text(model.title).font(.system(size: 17, weight: .semibold))
      Spacer()
      Text(model.lastReconciledText).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }
}

private struct ReconcileSetup: View {
  @Bindable var model: ReconcileModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.isCash
        ? "Check that the cash Abacus shows is the cash you hold. Nothing changes until you press Finish."
        : "Check that Abacus agrees with your bank. You tell Abacus what the bank says, it shows the difference, and you tick, add or fix rows until the difference is zero. Nothing changes until you press Finish.")
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.dateLabel).font(.system(size: 12, weight: .semibold))
          DatePicker(model.dateLabel, selection: $model.statementDay, displayedComponents: .date).labelsHidden()
          Text(model.isCash
            ? "The day you counted the cash. Rows after it are ignored."
            : "The last day your statement covers: the “balance as of” date on the PDF or in the bank app. Rows booked after it are ignored.")
            .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("\(model.statementLabel) (\(model.currencyCode))").font(.system(size: 12, weight: .semibold))
          TextField("0.00", text: $model.closingText)
            .multilineTextAlignment(.trailing)
            .frame(width: 140)
          Text(model.isCash
            ? "The total of the notes and coins you counted."
            : "The balance the bank shows at the end of that day. Abacus compares it with the account’s cleared balance on that day.")
            .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(model.setupSource).font(.system(size: 11)).foregroundStyle(.secondary)
      HStack {
        Button("Start reconciling") { model.start() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canStart)
        Button("Cancel") { model.cancel() }
      }
    }
    .padding(24)
    .frame(maxWidth: 700, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct ReconcileWorking: View {
  @Bindable var model: ReconcileModel

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let notice = model.notice {
            Text(notice)
              .font(.system(size: 13))
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.18)))
          }
          if let drift = model.driftNote {
            VStack(alignment: .leading, spacing: 2) {
              Text("The last reconciliation no longer adds up").font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
              Text(drift).font(.system(size: 12))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
          }
          statementBar
          figures
          if !model.isBalanced { help }
          if model.addForm != nil { ReconcileAddForm(model: model) }
          rows
        }
        .padding(20)
      }
      Divider()
      footer
    }
  }

  private var statementBar: some View {
    HStack(spacing: 12) {
      Text("\(model.dateLabel) ") + Text(model.statementDay.formatted(date: .abbreviated, time: .omitted)).fontWeight(.semibold)
      Text("\(model.statementLabel) ") + Text(model.statementText).fontWeight(.semibold)
      Button("Change") { model.changeStatement() }.controlSize(.small)
      Spacer()
    }
    .font(.system(size: 13))
  }

  private var figures: some View {
    HStack(spacing: 10) {
      tile(model.statementLabel, model.statementText, "at \(model.statementDay.formatted(date: .abbreviated, time: .omitted))", .primary)
      tile("Cleared balance", model.clearedText, "opening \(model.openingText) + cleared rows", .primary)
      tile("Difference", model.differenceText, model.differenceReason, model.isBalanced ? .green : .red)
    }
  }

  private func tile(_ title: String, _ value: String, _ hint: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(color).monospacedDigit()
      Text(hint).font(.system(size: 11)).foregroundStyle(color == .primary ? .secondary : color)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
  }

  private var help: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Ways to make the difference zero").font(.system(size: 13, weight: .semibold))
      Group {
        Text("1. Tick rows that are on the \(model.isCash ? "count" : "statement") (hand-typed payments the bank has booked).")
        Text("2. Add transaction for a payment the \(model.isCash ? "count" : "statement") has but Abacus does not. It is added already cleared.")
        Text("3. Edit a row whose amount or day differs, then tick it. Delete a hand-typed row that never happened.")
        Text("4. Mark settled a pending hold that was paid, or delete one that was released.")
        Text("5. Last resort: Add correction below books the remaining difference as a “Balance correction”.")
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      section(
        "To check (\(model.toCheck.count)) — tick what appears on the \(model.isCash ? "count" : "statement")",
        buttons: AnyView(HStack {
          Button("Add transaction") { model.beginAdd() }.controlSize(.small)
          Button(model.isCash ? "Tick all up to the date" : "Tick all") { model.tickAll() }.controlSize(.small)
        }))
      if model.toCheck.isEmpty {
        Text("Nothing left to check up to this date.").font(.system(size: 13)).foregroundStyle(.secondary).padding(14)
      }
      ForEach(model.toCheck) { row in ReconcileRowView(model: model, row: row, locked: false) }
      section(
        "Already cleared (\(model.alreadyCleared.count))",
        buttons: AnyView(Button(model.showCleared ? "Hide" : "Show") { model.showCleared.toggle() }.controlSize(.small)))
      if model.showCleared {
        ForEach(model.alreadyCleared) { row in ReconcileRowView(model: model, row: row, locked: !row.isStaged) }
      }
      if !model.afterDate.isEmpty {
        section("After the \(model.isCash ? "count" : "statement") date (\(model.afterDate.count)) — not part of this check", buttons: AnyView(EmptyView()))
        ForEach(model.afterDate) { row in
          HStack {
            Text(row.day).frame(width: 90, alignment: .leading)
            Text(row.payee)
            Spacer()
            Text(row.amount).monospacedDigit()
          }
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
        }
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func section(_ title: String, buttons: AnyView) -> some View {
    HStack {
      Text(title).font(.system(size: 12, weight: .semibold))
      Spacer()
      buttons
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .background(Color.secondary.opacity(0.08))
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text("Nothing is saved until Finish. A correction is a “Balance correction” row on the statement date, not counted as income or expense, and it is cleared.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Cancel") { model.cancel() }
      if let correction = model.correctionText {
        Button("Add correction \(correction) and finish") { Task { await model.finish(withCorrection: true) } }
      }
      Button("Finish reconciliation") { Task { await model.finish() } }
        .buttonStyle(.borderedProminent)
        .disabled(!model.isBalanced || model.isBusy)
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }
}

private struct ReconcileRowView: View {
  @Bindable var model: ReconcileModel
  let row: ReconcileModel.Row
  let locked: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Toggle(
          "Cleared: \(row.payee)",
          isOn: Binding(get: { row.isTicked }, set: { model.setTicked(row.id, $0) })
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(!row.canTick || locked)
        Text(row.day).frame(width: 90, alignment: .leading)
        VStack(alignment: .leading, spacing: 1) {
          Text(row.payee).lineLimit(1)
          if !row.detail.isEmpty { Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
        }
        Spacer(minLength: 8)
        Text(row.stateLabel)
          .font(.system(size: 11, weight: .semibold))
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Capsule().fill(row.isPending ? Color.orange.opacity(0.2) : row.isCleared || row.isStaged ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15)))
        if !locked {
          HStack(spacing: 10) {
            if row.canSettle { Button("Mark settled") { model.markSettled(row.id) }.buttonStyle(.link) }
            if row.canEdit { Button("Edit") { model.beginEdit(row.id) }.buttonStyle(.link) }
            if row.canDelete { Button("Delete") { model.delete(row.id) }.buttonStyle(.link).foregroundStyle(.red) }
          }
          .font(.system(size: 12))
        }
        Text(row.amount)
          .fontWeight(.semibold)
          .monospacedDigit()
          .foregroundStyle(row.isInflow ? Color.green : Color.primary)
          .frame(width: 120, alignment: .trailing)
      }
      .font(.system(size: 13))
      .opacity(locked ? 0.55 : 1)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(row.isTicked && !row.isCleared ? Color.accentColor.opacity(0.08) : Color.clear)
      if let edit = model.editForm, edit.id == row.id {
        HStack(alignment: .bottom, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Amount").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Amount", text: Binding(get: { edit.amountText }, set: { model.editForm?.amountText = $0 }))
              .multilineTextAlignment(.trailing).frame(width: 110)
          }
          VStack(alignment: .leading, spacing: 3) {
            Text("Day").font(.system(size: 11)).foregroundStyle(.secondary)
            DatePicker("Day", selection: Binding(get: { edit.day }, set: { model.editForm?.day = $0 }), displayedComponents: .date)
              .labelsHidden()
          }
          Button("Done") { model.commitEdit() }
          Text("Saved when you press Finish.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
      }
      Divider()
    }
  }
}

private struct ReconcileAddForm: View {
  @Bindable var model: ReconcileModel

  var body: some View {
    if let form = model.addForm {
      HStack(alignment: .bottom, spacing: 12) {
        field("Day") {
          DatePicker("Day", selection: Binding(get: { form.day }, set: { model.addForm?.day = $0 }), displayedComponents: .date)
            .labelsHidden()
        }
        field("Description") {
          TextField("e.g. Pharmacy", text: Binding(get: { form.description }, set: { model.addForm?.description = $0 }))
            .frame(width: 180)
        }
        field("Amount (\(model.currencyCode)), − for money out") {
          TextField("-25.00", text: Binding(get: { form.amountText }, set: { model.addForm?.amountText = $0 }))
            .multilineTextAlignment(.trailing).frame(width: 130)
        }
        field("Category") {
          Picker("Category", selection: Binding(get: { form.categoryID }, set: { model.addForm?.categoryID = $0 })) {
            Text("None").tag(AbacusDomain.Category.ID?.none)
            ForEach(model.categoryOptions, id: \.id) { option in Text(option.label).tag(Optional(option.id)) }
          }
          .labelsHidden()
          .frame(width: 170)
        }
        Button("Add (cleared)") { model.saveAdd() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canSaveAdd)
        Button("Cancel") { model.addForm = nil }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35)))
    }
  }

  private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
      content()
    }
  }
}
