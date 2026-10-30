import AbacusDomain
import AbacusFeatures
import AbacusImport
import SwiftUI

/// Step 2 (R-IMP-1): file bar, summary cards that filter, tabs, footer with Import N.
struct ImportReviewStep: View {
  @Bindable var model: ImportWizardModel

  var body: some View {
    VStack(spacing: 0) {
      ImportFileBar(model: model)
      ImportRule(color: ImportPalette.softRule)
      if model.needsTargetAccount {
        ImportTargetPrompt(model: model)
        Spacer(minLength: 0)
      } else {
        ImportCards(model: model)
        ImportTabBar(model: model)
        ImportRule(color: ImportPalette.border)
        tabContent
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      ImportRule()
      ImportFooter(model: model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.debtDraft != nil },
        set: { if !$0 { model.cancelDebt() } })
    ) {
      if let draft = model.debtDraft {
        DebtLinkSheet(initial: draft, onCancel: { model.cancelDebt() }, onSave: { model.saveDebt($0) })
      }
    }
    .sheet(
      isPresented: Binding(
        get: { model.refundPicker != nil },
        set: { if !$0 { model.cancelRefundPicker() } })
    ) {
      if let picker = model.refundPicker {
        RefundPickerSheet(
          model: picker.model, onChoose: { model.chooseRefundOption($0) }, onCancel: { model.cancelRefundPicker() })
      }
    }
    .sheet(
      isPresented: Binding(
        get: { model.ruleSheet != nil },
        set: { if !$0 { model.dismissRuleSheet() } })
    ) {
      if let sheet = model.ruleSheet {
        ImportRuleSheet(model: model, initial: sheet)
      }
    }
    .sheet(
      isPresented: Binding(
        get: { model.newCategoryDraft != nil },
        set: { if !$0 { model.cancelNewCategory() } })
    ) {
      if let draft = model.newCategoryDraft {
        ImportNewCategorySheet(model: model, initial: draft)
      }
    }
  }

  @ViewBuilder
  private var tabContent: some View {
    switch model.tab {
    case .transactions: ImportRowsTab(model: model)
    case .categoryAssignment: ImportRowsTab(model: model, onlyNeedingCategory: true)
    case .mapping: ImportMappingTab(model: model)
    case .events: ImportEventsTab(model: model)
    case .review: ImportNeedsReviewTab(model: model)
    }
  }
}

// MARK: - File bar

/// Name, detected format, rows and dates; PKO: "Import into <account>" (remembered).
struct ImportFileBar: View {
  let model: ImportWizardModel

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "doc")
        .foregroundStyle(ImportPalette.label)
      Text(model.file?.name ?? "")
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      Text(model.formatLabel)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(ImportPalette.accentText)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(ImportPalette.badge(.new).fill))
      Text(model.fileMeta)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .layoutPriority(-1)
      Spacer(minLength: 8)
      if model.file?.source == .pko {
        HStack(spacing: 6) {
          Text("Import into")
            .foregroundStyle(ImportPalette.label)
            .fixedSize()
          Picker("Import into", selection: target) {
            if model.targetAccountID == nil {
              Text("Choose account…").tag(Account.ID?.none)
            }
            AccountPickerItems(sections: model.targetSections) { account in
              Text("\(account.name) · \(account.currency.rawValue)").tag(Account.ID?.some(account.id))
            }
          }
          .labelsHidden()
          .fixedSize()
          if model.targetRemembered {
            Text("remembered")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .fixedSize()
          }
        }
        .font(.system(size: 13))
      }
    }
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.vertical, 12)
    .background(ImportPalette.bar)
  }

  private var target: Binding<Account.ID?> {
    Binding(
      get: { model.targetAccountID },
      set: { id in
        guard let id else { return }
        Task { await model.chooseTargetAccount(id) }
      })
  }
}

/// PKO statement without a remembered account (R-IMP-PKO-1).
struct ImportTargetPrompt: View {
  let model: ImportWizardModel

  var body: some View {
    let currency = model.file?.currency?.rawValue ?? "its currency"
    VStack(spacing: 10) {
      Image(systemName: "building.columns")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(.secondary)
      Text("Which account is this statement from?")
        .font(.system(size: 15, weight: .semibold))
      if model.targetOptions.isEmpty {
        Text("There is no active account in \(currency) yet. Add it in Accounts, then choose the file again.")
          .foregroundStyle(ImportPalette.label)
      } else {
        Text(
          "PKO BP statements don't name their account. Choose it in “Import into” above — the next statement in \(currency) goes there automatically."
        )
        .foregroundStyle(ImportPalette.label)
        .multilineTextAlignment(.center)
        HStack(spacing: 8) {
          ForEach(model.targetOptions) { account in
            Button("\(account.name) · \(account.currency.rawValue)") {
              Task { await model.chooseTargetAccount(account.id) }
            }
          }
        }
        .padding(.top, 4)
      }
    }
    .font(.system(size: 13))
    .frame(maxWidth: 560)
    .padding(.top, 40)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Summary cards

struct ImportCards: View {
  let model: ImportWizardModel

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
      ForEach(model.cards) { card in
        let isOn = model.filter == card.status
        Button {
          model.selectFilter(card.status)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(card.count)
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(ImportPalette.cardCount(card.status))
              .monospacedDigit()
            Text(card.label)
              .font(.system(size: 12, weight: .medium))
            Text(card.hint)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(2, reservesSpace: true)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? ImportPalette.accentFill : ImportPalette.surface))
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .strokeBorder(isOn ? ImportPalette.accent : ImportPalette.border, lineWidth: isOn ? 1.5 : 1)
          )
          .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.vertical, 14)
  }
}

// MARK: - Tabs

struct ImportTabBar: View {
  @Bindable var model: ImportWizardModel

  var body: some View {
    HStack(spacing: 2) {
      ForEach(model.tabs) { item in
        let isOn = model.tab == item.tab
        Button {
          model.tab = item.tab
        } label: {
          Text(item.label)
            .font(.system(size: 13, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? ImportPalette.accentText : ImportPalette.label)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
              Rectangle().fill(isOn ? ImportPalette.accent : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
      }
      Spacer()
    }
    .padding(.horizontal, ImportMetrics.horizontalPadding)
  }
}

// MARK: - Footer

/// Uncategorised count, rules to save, "All or nothing", Cancel, Import N.
struct ImportFooter: View {
  let model: ImportWizardModel

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        if model.preview != nil {
          Text(model.footerNote)
            .foregroundStyle(ImportPalette.label)
        } else {
          Text("Choose the account first. Nothing is saved until you import.")
            .foregroundStyle(ImportPalette.label)
        }
        if let blocking = model.blockingNote {
          Text(blocking)
            .foregroundStyle(ImportPalette.attention)
        }
      }
      .font(.system(size: 12))
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      if model.activity == .committing {
        ProgressView().controlSize(.small)
      }
      Button("Cancel") { model.cancel() }
        .keyboardShortcut(.cancelAction)
        .disabled(model.isBusy)
      Button(model.commitLabel) { Task { await model.commit() } }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canCommit)
    }
    .padding(.horizontal, ImportMetrics.horizontalPadding)
    .padding(.vertical, 12)
    .background(ImportPalette.bar)
  }
}
