import AbacusDomain
import Foundation

/// Tries its sources in order and returns the first answer (R-FX-1: Frankfurter, then NBU).
/// An empty answer is an answer (e.g. a range that is only a weekend); only errors fall through.
public struct FallbackRateSource: OfficialRateSource {
  public let sources: [any OfficialRateSource]

  public init(_ sources: [any OfficialRateSource]) {
    precondition(!sources.isEmpty, "A fallback chain needs at least one source")
    self.sources = sources
  }

  /// Frankfurter v2 `providers=NBU`, then the NBU API, over one session.
  public static func standard(session: URLSession = .shared) -> FallbackRateSource {
    FallbackRateSource([
      FrankfurterNBUProvider(session: session),
      NBUProvider(session: session),
    ])
  }

  public var name: String { sources.map(\.name).joined(separator: " → ") }

  public func uahRates(for currencies: [Currency], from: Day, to: Day) async throws -> [FXRate] {
    var failures: [String] = []
    for source in sources {
      try Task.checkCancellation()
      do {
        return try await source.uahRates(for: currencies, from: from, to: to)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failures.append("\(source.name): \(error)")
      }
    }
    throw FXError.allProvidersFailed(failures)
  }
}
