import AbacusDomain
import AbacusStore
import Foundation

/// Repository errors in words a model can act on.
func describeWriteError(_ error: any Error) -> ToolError {
  if let error = error as? ToolError { return error }
  switch error {
  case let error as RepositoryError:
    let text: String = switch error {
      case .notFound: "That record does not exist (anymore)."
      case .accountHasTransactions: "The account has transactions, so it cannot be deleted; archive it instead."
      case .categoryInUse: "The category is in use; give reassign_to (a category of the same kind) to move its records first."
      case .kindMismatch: "Expense and income categories cannot be mixed."
      case .invalidReassignTarget: "A category cannot be reassigned to itself or to one of its own subcategories."
      }
    return ToolError(text)
  case let error as StoreError:
    let text: String = switch error {
      case .currencyLocked: "An account's currency cannot change once it has transactions."
      case .invalidParent: "The parent must be an existing top-level category; a category with subcategories cannot become a subcategory."
      case .invalidBackup, .backupFromNewerVersion: "Backup files are not handled through MCP."
      }
    return ToolError(text)
  case let error as RefundError:
    let text: String = switch error {
      case .notFound: "The transaction to link does not exist."
      case .notRefundable: "Only an expense marked as a refund (or an income) can be linked as a refund; not a transfer, correction or debt leg."
      case .invalidOriginal: "The original must be an expense that is not itself a refund, correction or debt leg."
      case .exceedsOriginal(let remaining, let currency):
        "The refunds would exceed the original; at most \(Amounts.string(minor: remaining)) \(currency.rawValue) can still be refunded."
      case .rateUnavailable: "The refund is in another currency than the original and no rate is known for its date."
      }
    return ToolError(text)
  case let error as ImportMoveError:
    let text: String = switch error {
      case .notMovable: "Only a PKO statement's import that is not undone can be moved."
      case .invalidTarget: "The target must be another active account of the same currency, not a debt account."
      case .nothingToMove: "Nothing to move."
      case .refused(let count): "\(count) transaction(s) can no longer move (changed since the plan)."
      case .alreadyInTarget(let count): "\(count) row(s) are already imported into the target account."
      }
    return ToolError(text)
  default:
    return ToolError("The change failed: \(error.localizedDescription)")
  }
}
