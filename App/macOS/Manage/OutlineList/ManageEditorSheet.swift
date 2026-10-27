import SwiftUI

/// The editor sheet of the Categories and Accounts pages (D55): a title, the fields, messages,
/// then a footer with item actions (Archive, Delete…) on the left and Cancel + the primary Save
/// at the bottom-right (R-MGMT-10). Escape = Cancel, Return = Save while it can be saved.
///
/// It holds no draft itself: each sheet keeps its form as non-optional `@State` and hands it
/// to the model on Save, so a model reload never pulls a form out from under its fields.
struct ManageEditorSheet<Fields: View, Actions: View>: View {
  let title: String
  /// A validation message (shown once the form was edited).
  let message: String?
  let error: String?
  let saveTitle: String
  let canSave: Bool
  var width: CGFloat = 460
  let onCancel: () -> Void
  let onSave: () -> Void
  @ViewBuilder var fields: Fields
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(2)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
      VStack(alignment: .leading, spacing: 12) {
        fields
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 8) {
        if let message {
          Text(message).font(.caption).foregroundStyle(ManagePalette.negative)
        }
        if let error {
          Text(error).font(.caption).foregroundStyle(ManagePalette.negative)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
          actions
          Spacer(minLength: 12)
          Button("Cancel", role: .cancel, action: onCancel)
            .keyboardShortcut(.cancelAction)
          Button(saveTitle, action: onSave)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .overlay(alignment: .top) { Divider() }
    }
    .font(.system(size: 13))
    .frame(width: width)
  }
}
