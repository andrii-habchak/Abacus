import AbacusDomain
import Foundation

/// A confirmation dialog of the management screens (prototype "alertdialog"): title, message,
/// Cancel and a confirm button; the category delete adds a reassignment picker and
/// "Archive instead" (R-CAT-3).
public struct ManageDialog: Identifiable, Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case archiveAccount(Account.ID)
    case deleteAccount(Account.ID)
    case deleteAccountGroup(AccountGroup.ID)
    case deleteCategory(AbacusDomain.Category.ID)
    case deleteEvent(Event.ID)
    case deleteRule(CategoryRule.ID)
  }

  /// A reassignment target: subcategories are indented under their parent.
  public struct Target: Identifiable, Equatable, Sendable {
    public let id: AbacusDomain.Category.ID
    public let name: String
    public let isChild: Bool
  }

  public let action: Action
  public let title: String
  public let message: String
  public let confirmTitle: String
  /// Red confirm button.
  public let isDestructive: Bool
  /// Non-empty: "Move its transactions and budget limit to" picker.
  public let targets: [Target]
  /// "Archive instead" button (a category in use).
  public let offersArchive: Bool

  public var id: String { "\(action)" }
  public var needsTarget: Bool { !targets.isEmpty }

  init(
    action: Action, title: String, message: String, confirmTitle: String, isDestructive: Bool,
    targets: [Target] = [], offersArchive: Bool = false
  ) {
    self.action = action
    self.title = title
    self.message = message
    self.confirmTitle = confirmTitle
    self.isDestructive = isDestructive
    self.targets = targets
    self.offersArchive = offersArchive
  }
}

/// A user-facing message for a repository failure.
enum ManageFailure {
  static func message(_ error: any Error, doing action: String) -> String {
    switch error {
    case RepositoryError.accountHasTransactions:
      return "Couldn't \(action): the account has transactions. Archive it instead."
    case RepositoryError.categoryInUse:
      return "Couldn't \(action): the category is in use. Choose where its transactions go."
    case RepositoryError.kindMismatch:
      return "Couldn't \(action): the categories are of different kinds."
    case RepositoryError.notFound:
      return "Couldn't \(action): it no longer exists."
    default:
      return "Couldn't \(action): \(error.localizedDescription)"
    }
  }
}
