import AbacusDomain
import Foundation

/// Exchange rates (WP A2): Frankfurter v2 `providers=NBU` client with NBU fallback
/// (`RateProvider`), the in-memory `CurrencyConverter` (`RateTable`), the `RateRefresher`, and
/// helpers for the rates screen (R-FX-*).
///
/// All official rates are kept as "1 X = r UAH" (the NBU's own form) and every other pair is
/// a cross rate through UAH, so only exact published numbers are stored.
public enum AbacusFX {
  /// The currency every official rate is quoted in.
  public static let pivot: Currency = .UAH
}

/// Errors from rate providers and the refresher.
public enum FXError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The request did not reach the server or got no response (offline, DNS, timeout).
  case transport(String)
  /// The server answered with a non-2xx status.
  case http(status: Int, message: String?)
  /// The body could not be read as the expected JSON.
  case invalidResponse(String)
  /// A provider that fetches day by day refuses ranges longer than its limit.
  case rangeTooLong(days: Int, limit: Int)
  /// Every provider of a fallback chain failed; one message per provider.
  case allProvidersFailed([String])

  public var description: String {
    switch self {
    case .transport(let message): "network error: \(message)"
    case .http(let status, let message): "HTTP \(status)" + (message.map { ": \($0)" } ?? "")
    case .invalidResponse(let message): "invalid response: \(message)"
    case .rangeTooLong(let days, let limit): "range of \(days) days exceeds \(limit)"
    case .allProvidersFailed(let messages): messages.joined(separator: "; ")
    }
  }
}
