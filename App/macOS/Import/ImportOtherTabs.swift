import AbacusDomain
import AbacusFeatures
import AbacusImport
import SwiftUI

// MARK: - Accounts & categories (R-IMP-2)

/// Source accounts and categories → existing ones or "Create …"; remembered mappings marked.
struct ImportMappingTab: View {
  let model: ImportWizardModel

  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
        ForEach(model.mappingGroups) { group in
          ImportMappingGroupView(model: model, group: group)
        }
      }
      .padding(.horizontal, ImportMetrics.horizontalPadding)
      .padding(.vertical, 16)
    }
  }
}

struct ImportMappingGroupView: View {
  let model: ImportWizardModel
  let group: ImportMappingGroup

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(group.title).font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(group.summary).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(ImportPalette.bar)
      if group.items.isEmpty {
        ImportRule(color: ImportPalette.softRule)
        Text("Nothing to map in this file.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      ForEach(group.items) { item in
        ImportRule(color: ImportPalette.softRule)
        ImportMappingRow(model: model, item: item)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ImportPalette.border))
  }
}

struct ImportMappingRow: View {
  let model: ImportWizardModel
  let item: ImportMappingItem

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(item.source).lineLimit(1)
        Text(item.meta).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
      Image(systemName: "arrow.right")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
      VStack(alignment: .leading, spacing: 2) {
        if item.kind == .fixed {
          Text(item.selectionLabel).lineLimit(1)
        } else {
          if item.kind == .account {
            // C37: searchable; "Create …" is the picker's none row.
            AccountPicker(
              items: item.options.compactMap(\.account),
              selection: Binding(
                get: { if case .existing(let id) = item.selection { id } else { nil } },
                set: { id in binding.wrappedValue = id.map(ImportMappingChoice.existing) ?? .create }),
              noneTitle: item.options.first { $0.choice == .create }?.label ?? "Create new",
              width: 240, accessibilityTitle: "Map \(item.source)"
            )
            .controlSize(.small)
          } else {
            Picker("Map \(item.source)", selection: binding) {
              ForEach(item.options) { option in
                Text(option.label).tag(option.choice)
              }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 240, alignment: .leading)
          }
        }
        if let note = item.note {
          ImportNoteText(note: note)
        }
      }
      .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
  }

  private var binding: Binding<ImportMappingChoice> {
    Binding(
      get: { item.selection },
      set: { choice in
        switch item.kind {
        case .account: Task { await model.mapAccount(key: item.id, to: choice) }
        case .category: model.mapCategory(key: item.id, to: choice)
        case .fixed: break
        }
      })
  }
}

// MARK: - Events from tags (R-IMP-SALDO-4)

struct ImportEventsTab: View {
  let model: ImportWizardModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Saldo tags are not imported. Tick the ones that were trips or projects to turn them into events; their transactions keep their categories."
        )
        .font(.system(size: 13))
        .foregroundStyle(ImportPalette.label)
        .fixedSize(horizontal: false, vertical: true)
        if model.eventItems.isEmpty {
          Text("This file has no tags.")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        ForEach(model.eventItems) { item in
          Toggle(isOn: Binding(get: { item.isSelected }, set: { model.setEvent(tag: item.tag, selected: $0) })) {
            HStack(spacing: 10) {
              Text(item.tag).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
              Text(item.count).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
              VStack(alignment: .leading, spacing: 1) {
                Text(item.range).font(.system(size: 12)).foregroundStyle(.secondary)
                if let note = item.note {
                  Text(note).font(.system(size: 11)).foregroundStyle(ImportPalette.inflow)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13))
          }
          .toggleStyle(.checkbox)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(RoundedRectangle(cornerRadius: 8).strokeBorder(ImportPalette.border))
        }
      }
      .frame(maxWidth: 720, alignment: .leading)
      .padding(.horizontal, ImportMetrics.horizontalPadding)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Needs review (R-IMP-5)

struct ImportNeedsReviewTab: View {
  let model: ImportWizardModel

  var body: some View {
    VStack(spacing: 0) {
      ImportBulkBar(model: model)
      cards
    }
  }

  private var cards: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 12) {
          Text(model.reviewIntro)
            .font(.system(size: 13))
            .foregroundStyle(ImportPalette.label)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          if model.unresolvedReviewCount > 0 {
            Button("Use suggestions (\(model.unresolvedReviewCount.formatted()))") { model.acceptSuggestions() }
          }
        }
        if model.reviewItems.isEmpty {
          Text("Nothing needs a decision in this file.")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        LazyVStack(spacing: 10) {
          ForEach(model.reviewItems) { item in
            ImportReviewCard(model: model, item: item, isSelected: model.selection.contains(item.id))
          }
        }
      }
      .frame(maxWidth: 900, alignment: .leading)
      .padding(.horizontal, ImportMetrics.horizontalPadding)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct ImportReviewCard: View {
  let model: ImportWizardModel
  let item: ImportReviewItem
  var isSelected = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(item.title).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
        Text(item.date).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
      // Click selects the card for the bulk bar; Cmd toggles, Shift ranges.
      .onTapGesture { importSelect(model, item.id) }
      Text(item.detail)
        .foregroundStyle(ImportPalette.label)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 14) {
        ForEach(item.options) { option in
          ImportRadio(
            label: option.label, isOn: item.selected == option.option,
            isSuggested: item.selected == nil && item.suggested == option.option, isEnabled: option.isEnabled
          ) {
            if option.option == .debt {
              Task { await model.openDebt(forRow: item.id) }
            } else {
              model.selectReviewOption(option.option, forRow: item.id)
            }
          }
        }
        detailPicker
        Spacer(minLength: 0)
      }
      if item.selected == nil {
        Text("Needs a decision — the suggestion is marked.")
          .font(.system(size: 11))
          .foregroundStyle(ImportPalette.attention)
      }
    }
    .font(.system(size: 13))
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(ImportPalette.reviewFill))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(isSelected ? ImportPalette.accent : ImportPalette.reviewBorder, lineWidth: isSelected ? 2 : 1))
  }

  @ViewBuilder
  private var detailPicker: some View {
    switch item.selected {
    case .pair:
      Picker(
        "Pair with",
        selection: Binding(
          get: { item.selectedPair ?? item.pairCandidates.first?.choice },
          set: { if let choice = $0 { model.selectPairCandidate(choice, forRow: item.id) } })
      ) {
        ForEach(item.pairCandidates) { candidate in
          Text(candidate.label).tag(ReviewChoice?.some(candidate.choice))
        }
      }
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
    case .record:
      CategoryPicker(
        items: item.categoryOptions.filter { $0.choice != .none }.map(\.pickerItem),
        selection: Binding(
          get: { item.selectedCategory.map(ImportCategoryChoice.existing) },
          set: { choice in
            if case .existing(let id)? = choice {
              model.selectReviewCategory(id, forRow: item.id)
            } else if choice == .createNew {
              model.beginNewCategory(forRow: item.id)
            } else {
              model.selectReviewCategory(nil, forRow: item.id)
            }
          }),
        noneTitle: item.categoryOptions.first { $0.choice == .none }?.label
      )
      .controlSize(.small)
    case .transfer:
      AccountPicker(
        items: item.transferAccounts.map(\.pickerItem),
        selection: Binding(
          get: { item.selectedTransferAccount },
          set: { if let id = $0 { model.selectTransferAccount(id, forRow: item.id) } }),
        accessibilityTitle: "Other account"
      )
      .controlSize(.small)
    case .debt:
      HStack(spacing: 6) {
        Text(item.debtLabel ?? "Transfer to debt").font(.system(size: 12)).lineLimit(1)
        Button("Edit…") { Task { await model.openDebt(forRow: item.id) } }
          .buttonStyle(.link)
          .font(.system(size: 11))
      }
    case .skip, nil:
      EmptyView()
    }
  }
}

/// A radio button of a review choice; the importer's suggestion is marked until one is picked.
struct ImportRadio: View {
  let label: String
  let isOn: Bool
  let isSuggested: Bool
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(isOn ? ImportPalette.accent : .secondary)
        Text(label)
        if isSuggested {
          Text("suggested")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ImportPalette.accentText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(ImportPalette.accentFill))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.5)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
