import Foundation
import Observation

/// Holds the app's current `AppSession`. Moving the data folder (R-SET-1) replaces the session
/// with one on the moved database; the windows read `session` from here so they follow.
@MainActor
@Observable
public final class AppSessionHost {
  public private(set) var session: AppSession

  public init(_ session: AppSession) {
    self.session = session
    adopt(session)
  }

  private func adopt(_ session: AppSession) {
    session.onReplace = { [weak self] next in
      guard let self else { return }
      self.session = next
      self.adopt(next)
    }
  }
}
