import AbacusFeatures
import SwiftUI

/// Settings › Security (approved prototype N7, R-LOCK-2, R-LOCK-10).
struct SecuritySettingsView: View {
  @Environment(AppLockModel.self) private var lock

  var body: some View {
    Form {
      if let message = lock.settingsMessage {
        Text(message)
          .font(.callout)
          .foregroundStyle(.orange)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }
      LabeledContent("App lock:") {
        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            "Require Touch ID or password to open Abacus",
            isOn: Binding(get: { lock.enabled }, set: { on in Task { await lock.setEnabled(on) } }))
          Hint("Off by default. Turning it on asks you to authenticate once.")
        }
      }
      LabeledContent("Lock after:") {
        Picker(
          "Lock after",
          selection: Binding(get: { lock.idle }, set: { value in Task { await lock.setIdle(value) } })
        ) {
          ForEach(LockIdle.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(!lock.enabled)
      }
      LabeledContent("") {
        VStack(alignment: .leading, spacing: 4) {
          Button("Lock now") { lock.lockNow() }
            .disabled(!lock.enabled)
          Hint("Shortcut: ⌥⌘L. Uses Touch ID, Apple Watch or your Mac password, chosen by macOS. This device only: not part of backups or sync.")
        }
      }
      GroupBox("What the lock does not do") {
        VStack(alignment: .leading, spacing: 6) {
          Text("It hides Abacus's window; it does not encrypt your data.")
          Text("The database file stays readable by other apps and tools.")
          Text("The MCP server (abacus-mcp) and abacus-import are separate programs that open the file directly and are not gated by the lock.")
          Text("FileVault protects the disk if the Mac is lost or stolen.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
      }
    }
    .formStyle(.columns)
    .onDisappear { lock.clearSettingsMessage() }
  }
}
