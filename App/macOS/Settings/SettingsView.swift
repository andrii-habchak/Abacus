import AbacusDomain
import AbacusFeatures
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, Hashable, CaseIterable {
  case general, rates, data
}

/// The Settings window (⌘,), tabs General / Rates / Data (approved prototype group 6, R-SET-1…3).
struct SettingsView: View {
  @Environment(AppModel.self) private var app
  @State private var tab: SettingsTab = LaunchOptions.current.settingsTab ?? .general

  var body: some View {
    TabView(selection: $tab) {
      Tab("General", systemImage: "gearshape", value: .general) {
        GeneralSettingsView()
      }
      Tab("Rates", systemImage: "arrow.left.arrow.right", value: .rates) {
        RatesSettingsView()
      }
      Tab("Data", systemImage: "cylinder.split.1x2", value: .data) {
        DataSettingsView(model: app.data)
      }
    }
    .scenePadding()
    .frame(width: 560)
    .task {
      if !app.isLoaded { await app.load() }
    }
  }
}

// MARK: - General

struct GeneralSettingsView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Form {
      LabeledContent("Display currency:") {
        VStack(alignment: .leading, spacing: 4) {
          DisplayCurrencyPicker()
          Hint("Default for the dashboard and totals; each screen can still switch.")
        }
      }
      LabeledContent("Refunds:") {
        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            "Refunds reduce category spending",
            isOn: Binding(get: { app.refundsReduceSpending }, set: { app.setRefundsReduceSpending($0) }))
          Hint(app.refundsHint)
        }
      }
    }
    .formStyle(.columns)
  }
}

// MARK: - Rates

struct RatesSettingsView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Form {
      LabeledContent("Updates:") {
        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            "Update rates automatically",
            isOn: Binding(get: { app.ratesAutoRefresh }, set: { app.setRatesAutoRefresh($0) }))
          Hint(app.autoRatesHint)
        }
      }
      LabeledContent("Source:") {
        VStack(alignment: .leading, spacing: 4) {
          Text("Official NBU rates")
          Hint("Via Frankfurter (providers=NBU); falls back to the NBU API. No account or key needed.")
        }
      }
      LabeledContent("Manual rates:") {
        Text("\(app.manualRateCountText) · managed on the Exchange rates screen")
      }
    }
    .formStyle(.columns)
  }
}

// MARK: - Data

struct DataSettingsView: View {
  @Bindable var model: DataSettingsModel

  var body: some View {
    Form {
      LabeledContent("Data folder:") {
        VStack(alignment: .leading, spacing: 6) {
          Text(model.databasePath)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Show in Finder", action: showInFinder)
              .disabled(model.databaseURL == nil)
            Button("Change…", action: chooseFolder)
          }
        }
      }
      LabeledContent("Backup:") {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Button("Export backup…", action: exportBackup)
            Button("Restore from backup…", action: chooseBackup)
          }
          .disabled(model.isWorking)
          Hint(model.backupNote)
          if let message = model.message {
            Text(message)
              .font(.caption)
              .foregroundStyle(model.messageIsError ? Color.red : Color.secondary)
          }
        }
      }
    }
    .formStyle(.columns)
    .alert(
      model.restoreTitle,
      isPresented: Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.cancelRestore() } })
    ) {
      Button("Cancel", role: .cancel) { model.cancelRestore() }
      Button("Replace all data", role: .destructive) {
        Task { await model.confirmRestore() }
      }
    } message: {
      Text(DataSettingsModel.restoreMessage)
    }
  }

  private static var backupType: UTType {
    UTType(filenameExtension: DataSettingsModel.backupExtension) ?? .data
  }

  private func showInFinder() {
    guard let url = model.databaseURL else { return }
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use This Folder"
    panel.message = "Choose the folder for the Abacus database."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.moveDatabase(to: url) }
  }

  private func exportBackup() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = model.suggestedBackupName
    panel.canCreateDirectories = true
    panel.message = "Export all Abacus data to one file."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.export(to: url) }
  }

  private func chooseBackup() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [Self.backupType]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Restore"
    panel.message = "Choose an Abacus backup. All current data will be replaced."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.askRestore(from: url)
  }
}

/// Secondary explanation under a control.
struct Hint: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 360, alignment: .leading)
  }
}

#Preview("General") {
  GeneralSettingsView()
    .environment(AppModel(environment: .preview()))
    .padding()
    .frame(width: 560)
}

#Preview("Settings") {
  SettingsView()
    .environment(AppModel(environment: .preview()))
}
