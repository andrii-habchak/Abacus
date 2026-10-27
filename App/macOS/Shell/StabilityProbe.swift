#if DEBUG || ABACUS_PROBE
  import AbacusDomain
  import AbacusFeatures
  import AppKit

  /// Debug builds only (S1): checks the app for hangs and crashes without driving the UI.
  ///
  /// - `-AbacusHangWatch YES`: a background thread pings the main thread every 50 ms and prints
  ///   `HANG <ms>` to stderr whenever it was blocked for more than 100 ms.
  /// - `-AbacusSoak YES [-AbacusSoakRounds <n>]`: switches through every section, then repeats
  ///   what crashed in 1.2.0 through the live screens — a debt record saved and cancelled while
  ///   its sheet is up (Forgive), a debt form cancelled, the transaction editor opened and closed,
  ///   an account and a category dragged — printing `SOAK …` timings, then quits.
  ///   Use only on a scratch database (`-AbacusDatabasePath`): it writes records.
  @MainActor
  enum StabilityProbe {
    static func runIfRequested(session: AppSession) async {
      let defaults = UserDefaults.standard
      guard defaults.bool(forKey: "AbacusSoak") else { return }
      let rounds = max(1, defaults.integer(forKey: "AbacusSoakRounds"))
      try? await Task.sleep(for: .seconds(2))
      let clock = ContinuousClock()
      let start = clock.now
      for round in 1...rounds {
        for section in AppSection.allCases where section != .importFiles {
          let begin = clock.now
          session.app.section = section
          await session.sectionAppeared(section)
          log("round \(round) section \(section.rawValue) reloaded in \(ms(clock.now - begin))")
          try? await Task.sleep(for: .milliseconds(600))
        }
        await debts(session)
        await editor(session)
        await dragAndDrop(session)
      }
      log("done in \(ms(clock.now - start))")
      try? await Task.sleep(for: .milliseconds(500))
      NSApp.terminate(nil)
    }

    private static func debts(_ session: AppSession) async {
      let model = session.debts
      session.app.section = .debts
      await model.load()
      guard let debt = model.selectedDetails.first?.debt else { return log("debts: none") }
      // Forgive, saved while the sheet is up (crash 1 of 1.2.0).
      model.newRecord(debtID: debt.id, kind: .forgaveThem)
      try? await Task.sleep(for: .milliseconds(500))
      model.recordDraft?.amount = "1"
      await model.saveRecordDraft()
      try? await Task.sleep(for: .milliseconds(500))
      // Save pressed twice: one record only.
      let before = model.selectedDetails.first?.records.count ?? 0
      model.newRecord(debtID: debt.id, kind: .lent)
      try? await Task.sleep(for: .milliseconds(400))
      model.recordDraft?.amount = "2"
      async let first: Void = model.saveRecordDraft()
      async let second: Void = model.saveRecordDraft()
      _ = await (first, second)
      let after = model.selectedDetails.first?.records.count ?? 0
      log("debts: double save added \(after - before) record(s)")
      try? await Task.sleep(for: .milliseconds(500))
      // Escape / Cancel on both forms (crash 2 of 1.2.0).
      model.newRecord(debtID: debt.id)
      try? await Task.sleep(for: .milliseconds(400))
      model.recordDraft = nil
      model.editDebt(debt.id)
      try? await Task.sleep(for: .milliseconds(400))
      model.debtDraft = nil
      try? await Task.sleep(for: .milliseconds(400))
      log("debts: saved, double-saved and cancelled forms")
    }

    private static func editor(_ session: AppSession) async {
      session.app.section = .transactions
      try? await Task.sleep(for: .milliseconds(400))
      session.app.editor = .new
      try? await Task.sleep(for: .milliseconds(700))
      session.app.editor = nil
      try? await Task.sleep(for: .milliseconds(400))
      log("editor: opened and closed")
    }

    private static func dragAndDrop(_ session: AppSession) async {
      session.app.section = .accounts
      await session.accounts.load()
      let accounts = session.accounts.rows.filter { !$0.isGroup }
      if accounts.count > 3 {
        await session.accounts.drop(accounts[3].id, on: accounts[0].id, position: .before)
      }
      session.app.section = .categories
      await session.categories.load()
      let categories = session.categories.rows
      if categories.count > 3 {
        await session.categories.drop(categories[3].id, on: categories[0].id, position: .before)
      }
      try? await Task.sleep(for: .milliseconds(500))
      log("drag and drop: account and category moved")
    }

    static func log(_ text: String) {
      FileHandle.standardError.write(Data("SOAK \(text)\n".utf8))
    }

    static func ms(_ duration: Duration) -> String {
      "\(Int(Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)) ms"
    }
  }

  /// Prints `HANG <ms>` when the main thread did not answer within 100 ms.
  enum HangWatch {
    nonisolated static func start() {
      Thread.detachNewThread {
        while true {
          let sent = DispatchTime.now().uptimeNanoseconds
          let answered = DispatchSemaphore(value: 0)
          DispatchQueue.main.async { answered.signal() }
          answered.wait()
          let blocked = (DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
          if blocked > 100 {
            FileHandle.standardError.write(Data("HANG main thread blocked \(blocked) ms\n".utf8))
          }
          Thread.sleep(forTimeInterval: 0.05)
        }
      }
    }
  }
#endif
