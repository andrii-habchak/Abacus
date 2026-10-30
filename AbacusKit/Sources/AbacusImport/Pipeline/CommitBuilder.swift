import AbacusDomain
import Foundation

/// What an import did, for the done screen and the history (R-IMP-6).
public struct ImportSummary: Hashable, Sendable {
  public var batch: ImportBatch
  /// New transactions.
  public var created = 0
  /// Of those, transfers made of two halves (Saldo pairing or manual pairing).
  public var transfersPaired = 0
  /// Pending holds upgraded by their settled rows (R-IMP-PKO-2).
  public var settled = 0
  /// Existing transactions that got this import's fingerprints (link, other side of a transfer).
  public var linked = 0
  /// Of those, debt records entered by hand that rows matched (R-DEBT-13).
  public var debtRecordsMatched = 0
  /// New transactions recorded as debt records (row action and rules, R-DEBT-10/12).
  public var debtRecords = 0
  /// Existing expenses/incomes turned into transfers.
  public var transfersCompleted = 0
  public var alreadyImported = 0
  public var duplicatesSkipped = 0
  public var duplicatesImported = 0
  public var reviewedImported = 0
  public var reviewedSkipped = 0
  public var skipped = 0
  public var accountsCreated = 0
  public var categoriesCreated = 0
  public var eventsCreated = 0
  public var rulesSaved = 0
  public var openingBalancesSet = 0
  /// Imported rows that carry a warning from the parser.
  public var warningsKept = 0

  /// One line per fact, for the done screen.
  public var lines: [String] {
    var lines: [String] = []
    var first = "\(created) transaction\(created == 1 ? "" : "s") imported"
    if transfersPaired > 0 { first += " · \(transfersPaired) transfer\(transfersPaired == 1 ? "" : "s") paired" }
    lines.append(first)
    var created: [String] = []
    if accountsCreated > 0 { created.append("\(accountsCreated) account\(accountsCreated == 1 ? "" : "s")") }
    if categoriesCreated > 0 { created.append("\(categoriesCreated) categor\(categoriesCreated == 1 ? "y" : "ies")") }
    if !created.isEmpty {
      lines.append(created.joined(separator: " and ") + " created" + (openingBalancesSet > 0 ? ", opening balances set" : ""))
    }
    var matched: [String] = []
    if settled > 0 { matched.append("\(settled) pending payment\(settled == 1 ? "" : "s") settled") }
    if alreadyImported > 0 { matched.append("\(alreadyImported) already imported, skipped") }
    if linked > 0 { matched.append("\(linked) linked to existing") }
    if transfersCompleted > 0 { matched.append("\(transfersCompleted) transfer\(transfersCompleted == 1 ? "" : "s") completed") }
    if debtRecordsMatched > 0 {
      matched.append("\(debtRecordsMatched) matched debt record\(debtRecordsMatched == 1 ? "" : "s")")
    }
    if !matched.isEmpty { lines.append(matched.joined(separator: " · ")) }
    if debtRecords > 0 { lines.append("\(debtRecords) recorded as debt record\(debtRecords == 1 ? "" : "s")") }
    var review: [String] = []
    if duplicatesSkipped > 0 { review.append("\(duplicatesSkipped) possible duplicate\(duplicatesSkipped == 1 ? "" : "s") skipped") }
    if duplicatesImported > 0 { review.append("\(duplicatesImported) possible duplicate\(duplicatesImported == 1 ? "" : "s") imported") }
    if reviewedImported + reviewedSkipped > 0 {
      review.append("\(reviewedImported + reviewedSkipped) reviewed row\(reviewedImported + reviewedSkipped == 1 ? "" : "s") resolved")
    }
    if warningsKept > 0 { review.append("\(warningsKept) with warnings") }
    if !review.isEmpty { lines.append(review.joined(separator: " · ")) }
    if eventsCreated > 0 { lines.append("\(eventsCreated) event\(eventsCreated == 1 ? "" : "s") created from tags") }
    if rulesSaved > 0 { lines.append("\(rulesSaved) new categorisation rule\(rulesSaved == 1 ? "" : "s") saved") }
    return lines
  }
}

/// Turns a ready preview into one `ImportCommit` and its summary.
struct CommitBuilder {
  let preview: ImportPreview
  let calendar: Calendar
  let now: Date

  private var context: ImportContext { preview.context }

  func build() -> (commit: ImportCommit, summary: ImportSummary) {
    let batchID = preview.batchID
    var summary = ImportSummary(batch: ImportBatch(id: batchID, source: preview.source, fileName: preview.fileName))

    // Which new accounts and categories are needed.
    var neededAccounts = Set<String>()
    var neededCategories = Set<String>()
    var openings: [String: Int64] = [:]
    func need(_ ref: AccountRef?) { if case .new(let key)? = ref { neededAccounts.insert(key) } }
    func need(_ ref: CategoryRef?) { if case .new(let key)? = ref { neededCategories.insert(key) } }
    for plan in preview.plans {
      switch plan {
      case .openingBalance(.new(let key), let amount, _):
        neededAccounts.insert(key)
        openings[key, default: 0] += amount
      case .create(let shape), .convert(_, let shape):
        need(shape.from)
        need(shape.to)
        need(shape.category)
        shape.lines.forEach { need(preview.categoryRef($0.category)) }
      case .nothing, .openingBalance, .settle, .link: break
      }
    }

    // Accounts (R-ACC-2, R-ACC-4, R-IMP-SALDO-3).
    var accountIDs: [String: Account.ID] = [:]
    var newAccounts: [Account] = []
    var position = (context.accounts.map(\.position).max() ?? -1) + 1
    let firstDates = firstDates()
    for mapping in preview.accountMappings where neededAccounts.contains(mapping.id) {
      let id = UUID()
      accountIDs[mapping.id] = id
      let opening = openings[mapping.id] ?? 0
      if opening != 0 { summary.openingBalancesSet += 1 }
      newAccounts.append(
        Account(
          id: id, name: mapping.newName, currency: mapping.external.currency, kind: mapping.newKind,
          openingBalanceMinor: opening,
          openingDate: calendar.startOfDay(for: firstDates[mapping.id] ?? now),
          iban: mapping.external.iban, position: position, isArchived: mapping.newIsArchived,
          importBatchID: batchID))
      position += 1
    }
    func accountID(_ ref: AccountRef) -> Account.ID {
      switch ref {
      case .existing(let id): id
      case .new(let key): accountIDs[key]!
      }
    }

    // Categories (R-CAT-2): parents named by the source are reused or created once.
    var categoryIDs: [String: AbacusDomain.Category.ID] = [:]
    var newCategories: [AbacusDomain.Category] = []
    var categoryPosition = (context.categories.map(\.position).max() ?? -1) + 1
    var newParents: [String: AbacusDomain.Category.ID] = [:]
    for mapping in preview.categoryMappings where neededCategories.contains(mapping.id) {
      var parentID: AbacusDomain.Category.ID?
      if let parentName = mapping.external.parentName {
        let parentKey = "\(mapping.external.kind.rawValue)|\(parentName)"
        if let existing = context.categories.first(where: {
          $0.parentID == nil && $0.kind == mapping.external.kind && MappingResolver.same($0.name, parentName)
        }) {
          parentID = existing.id
        } else if let created = newParents[parentKey] {
          parentID = created
        } else {
          let parent = AbacusDomain.Category(
            name: parentName, kind: mapping.external.kind, position: categoryPosition, importBatchID: batchID)
          categoryPosition += 1
          newParents[parentKey] = parent.id
          newCategories.append(parent)
          parentID = parent.id
        }
      }
      let category = AbacusDomain.Category(
        name: mapping.external.name, kind: mapping.external.kind, parentID: parentID, position: categoryPosition,
        importBatchID: batchID)
      categoryPosition += 1
      categoryIDs[mapping.id] = category.id
      newCategories.append(category)
    }
    func categoryID(_ ref: CategoryRef?) -> AbacusDomain.Category.ID? {
      switch ref {
      case .existing(let id): id
      case .new(let key): categoryIDs[key]
      case nil: nil
      }
    }

    // Events from ticked tags (R-IMP-SALDO-4); created only when a new transaction uses them.
    var usedTags = Set<String>()
    for plan in preview.plans {
      if case .create(let shape) = plan, let tag = shape.tag { usedTags.insert(tag) }
    }
    var eventIDs: [String: Event.ID] = [:]
    var newEvents: [Event] = []
    for candidate in preview.eventCandidates where candidate.isSelected {
      if let existing = candidate.existingEventID {
        eventIDs[candidate.tag] = existing
      } else if usedTags.contains(candidate.tag) {
        let event = Event(
          name: candidate.tag, startDay: candidate.firstDay.string, endDay: candidate.lastDay.string,
          importBatchID: batchID)
        eventIDs[candidate.tag] = event.id
        newEvents.append(event)
      }
    }

    // Transactions.
    let source = TxnSource(rawValue: preview.source.rawValue) ?? .manual
    var txns: [TxnWithLines] = []
    var fingerprints: [ImportFingerprint] = []
    var updated: [Txn] = []
    var debtLinks: [ImportDebtLink] = []
    var ruleHits: [CategoryRule.ID: Int] = [:]
    for (row, plan) in zip(preview.rows, preview.plans) {
      switch plan {
      case .nothing, .openingBalance:
        break
      case .create(let shape):
        let txn = Txn(
          type: shape.type, occurredAt: shape.occurredAt, accountID: accountID(shape.from),
          amountMinor: shape.amountMinor,
          categoryID: shape.type == .transfer ? nil : categoryID(shape.category),
          toAccountID: shape.to.map(accountID), toAmountMinor: shape.type == .transfer ? shape.toAmountMinor : nil,
          isRefund: shape.isRefund, originalAmountMinor: shape.original?.minorUnits,
          originalCurrencyCode: shape.original?.currencyCode, payee: shape.payee, note: shape.note,
          eventID: shape.tag.flatMap { eventIDs[$0] }, source: source, isPendingAtBank: shape.isPending,
          createdAt: now, bookedDay: shape.bookedDay?.string)
        let lines = shape.lines.enumerated().map { index, line in
          AttachedRecord(
            txnID: txn.id, kind: line.kind, categoryID: categoryID(preview.categoryRef(line.category)),
            amountMinor: line.amountMinor, originalAmountMinor: line.original?.minorUnits,
            originalCurrencyCode: line.original?.currencyCode, note: line.note, position: index)
        }
        txns.append(TxnWithLines(txn: txn, lines: lines))
        fingerprints += shape.fingerprints.map { ImportFingerprint(id: $0, txnID: txn.id) }
        if let debt = shape.debt {
          // R-DEBT-10/12: the store turns the new transaction into the record's leg.
          debtLinks.append(
            ImportDebtLink(
              txnID: txn.id,
              link: DebtLink(
                personName: debt.personName, debtID: debt.debtID, currency: debt.currency, kind: debt.kind,
                amountMinor: debt.amountMinor, countsInReports: debt.countsInReports)))
          summary.debtRecords += 1
        }
        if let rule = shape.ruleID { ruleHits[rule, default: 0] += 1 }
        summary.created += 1
        if shape.type == .transfer, shape.fingerprints.count > 1 { summary.transfersPaired += 1 }
        if !row.warnings.isEmpty { summary.warningsKept += 1 }
        if row.status == .possibleDuplicate { summary.duplicatesImported += 1 }
      case .settle(var hold, let settled):
        // R-IMP-PKO-2: the settled amount wins, the purchase day stays, the booking day is kept.
        hold.amountMinor = settled.amountMinor
        hold.isPendingAtBank = false
        // The settled payment is money out (C16: older builds could store a hold as a refund).
        hold.isRefund = false
        if let booked = settled.bookedDay, booked != Day(hold.occurredAt, calendar: calendar) {
          hold.bookedDay = booked.string
        }
        if let original = settled.original {
          hold.originalAmountMinor = original.minorUnits
          hold.originalCurrencyCode = original.currencyCode
        }
        updated.append(hold)
        fingerprints += settled.fingerprints.map { ImportFingerprint(id: $0, txnID: hold.id) }
        summary.settled += 1
      case .link(let existing, let keys):
        fingerprints += keys.map { ImportFingerprint(id: $0, txnID: existing.id) }
        summary.linked += 1
        if existing.debtRecordID != nil { summary.debtRecordsMatched += 1 }
      case .convert(var existing, let shape):
        existing.type = .transfer
        existing.accountID = accountID(shape.from)
        existing.amountMinor = shape.amountMinor
        existing.toAccountID = shape.to.map(accountID)
        existing.toAmountMinor = shape.toAmountMinor
        existing.categoryID = nil
        existing.isRefund = false
        existing.originalAmountMinor = nil
        existing.originalCurrencyCode = nil
        updated.append(existing)
        fingerprints += shape.fingerprints.map { ImportFingerprint(id: $0, txnID: existing.id) }
        summary.transfersCompleted += 1
      }
      if let review = row.review {
        if review.choice == .skip { summary.reviewedSkipped += 1 } else { summary.reviewedImported += 1 }
      }
      if row.status == .possibleDuplicate, row.duplicate?.action == .skip { summary.duplicatesSkipped += 1 }
    }
    summary.alreadyImported = preview.counts.alreadyImported
    summary.skipped = preview.counts.skipped

    // Remembered mappings (R-IMP-2, R-IMP-PKO-1).
    var mappings: [ImportMapping] = []
    func remember(_ kind: MappingKind, _ key: String, _ target: UUID?) {
      guard let target else { return }
      let id = context.remembered(kind, key)?.id ?? UUID()
      mappings.append(ImportMapping(id: id, source: preview.source, kind: kind, externalKey: key, targetID: target))
    }
    for mapping in preview.accountMappings {
      switch mapping.target {
      case .existing(let id): remember(.account, mapping.id, id)
      case .create: remember(.account, mapping.id, accountIDs[mapping.id])
      }
    }
    for mapping in preview.categoryMappings {
      switch mapping.target {
      case .existing(let id): remember(.category, mapping.id, id)
      case .create: remember(.category, mapping.id, categoryIDs[mapping.id])
      }
    }
    if preview.source == .pko, let target = preview.targetAccountID, let account = context.account(target) {
      remember(.account, ImportPipeline.statementKey(account.currency), target)
    }

    // Rules (R-IMP-8): learned ones, and hit counts of the ones applied.
    var rules: [CategoryRule] = []
    var rulePosition = (context.rules.map(\.position).max() ?? -1) + 1
    for proposal in preview.rulesToSave {
      rules.append(
        CategoryRule(
          pattern: proposal.pattern, categoryID: proposal.categoryID, origin: .imported,
          hitCount: proposal.rowCount, position: rulePosition))
      rulePosition += 1
    }
    for rule in context.rules {
      guard let hits = ruleHits[rule.id] else { continue }
      var rule = rule
      rule.hitCount += hits
      rules.append(rule)
    }

    summary.accountsCreated = newAccounts.count
    summary.categoriesCreated = newCategories.count
    summary.eventsCreated = newEvents.count
    summary.rulesSaved = preview.rulesToSave.count
    summary.batch.importedAt = now
    summary.batch.accountID = preview.targetAccountID
    summary.batch.summary = batchSummary(summary)

    let commit = ImportCommit(
      batch: summary.batch, newAccounts: newAccounts, newCategories: newCategories, newEvents: newEvents,
      txns: txns, fingerprints: fingerprints, updatedTxns: updated, mappings: mappings, rules: rules,
      debtLinks: debtLinks)
    return (commit, summary)
  }

  /// Earliest date of any row touching each source account: the opening date of a new account.
  private func firstDates() -> [String: Date] {
    var result: [String: Date] = [:]
    for row in preview.parsedRows {
      for account in [row.account] + (row.counterAccount.map { [$0] } ?? []) {
        result[account.key] = min(result[account.key] ?? row.occurredAt, row.occurredAt)
      }
    }
    return result
  }

  /// "Saldo · 4,612 new · 139 reviewed · 31 accounts, 24 categories created".
  private func batchSummary(_ s: ImportSummary) -> String {
    var parts: [String] = []
    if preview.source == .pko {
      parts.append(preview.targetAccountID.flatMap { context.account($0)?.name } ?? "PKO BP")
    } else {
      parts.append("Saldo")
    }
    parts.append("\(s.created) new")
    if s.settled > 0 { parts.append("\(s.settled) settled") }
    if s.linked > 0 { parts.append("\(s.linked) linked") }
    if s.debtRecords > 0 { parts.append(s.debtRecords == 1 ? "1 debt record" : "\(s.debtRecords) debt records") }
    if s.alreadyImported > 0 { parts.append("\(s.alreadyImported) skipped") }
    if s.duplicatesSkipped > 0 {
      parts.append(s.duplicatesSkipped == 1 ? "1 possible duplicate skipped" : "\(s.duplicatesSkipped) possible duplicates skipped")
    }
    if s.reviewedImported + s.reviewedSkipped > 0 { parts.append("\(s.reviewedImported + s.reviewedSkipped) reviewed") }
    var created: [String] = []
    if s.accountsCreated > 0 { created.append(s.accountsCreated == 1 ? "1 account" : "\(s.accountsCreated) accounts") }
    if s.categoriesCreated > 0 { created.append(s.categoriesCreated == 1 ? "1 category" : "\(s.categoriesCreated) categories") }
    if !created.isEmpty { parts.append(created.joined(separator: ", ") + " created") }
    return parts.joined(separator: " · ")
  }
}
