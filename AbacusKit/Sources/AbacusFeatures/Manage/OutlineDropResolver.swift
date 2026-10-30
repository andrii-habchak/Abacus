import Foundation

/// Turns an outline view's drop proposal into what the page models understand (D55): the
/// Categories and Accounts lists are `NSOutlineView`s that propose "onto item" or "child index N
/// of parent P"; the models take `(target, .before / .after / .onto)`. Kept free of AppKit so
/// every case is unit-tested.
public struct OutlineDropResolver: Sendable {
  public struct Node: Sendable, Equatable {
    public let id: UUID
    public let isPinned: Bool
    public let children: [UUID]

    public init(id: UUID, isPinned: Bool = false, children: [UUID] = []) {
      self.id = id
      self.isPinned = isPinned
      self.children = children
    }
  }

  /// What the model is asked, and the child index the outline should show its feedback at
  /// (nil = onto the item).
  public struct Resolved: Sendable, Equatable {
    public let target: UUID?
    public let position: CategoryDropPosition
    public let index: Int?

    public init(target: UUID?, position: CategoryDropPosition, index: Int?) {
      self.target = target
      self.position = position
      self.index = index
    }
  }

  public let roots: [Node]

  public init(roots: [Node]) {
    self.roots = roots
  }

  /// - `index` nil: onto `parent` (never onto a pinned row);
  /// - `parent` nil: between top-level rows — before the row at `index` (skipping pinned rows,
  ///   nothing lands above them), or after everything (`target` nil: top level, last);
  /// - inside a parent: before its child at `index`, after its last child, or onto an empty
  ///   parent.
  public func resolve(parent: UUID?, index: Int?) -> Resolved? {
    guard let index else {
      guard let parent, let node = roots.first(where: { $0.id == parent }) ?? childNode(parent),
        !node.isPinned
      else { return nil }
      return Resolved(target: parent, position: .onto, index: nil)
    }
    guard let parent else {
      var at = max(0, index)
      while at < roots.count, roots[at].isPinned { at += 1 }
      if at < roots.count { return Resolved(target: roots[at].id, position: .before, index: at) }
      return Resolved(target: nil, position: .after, index: roots.count)
    }
    guard let node = roots.first(where: { $0.id == parent }) else { return nil }
    if index >= 0, index < node.children.count {
      return Resolved(target: node.children[index], position: .before, index: index)
    }
    if let last = node.children.last { return Resolved(target: last, position: .after, index: node.children.count) }
    return Resolved(target: parent, position: .onto, index: nil)
  }

  /// The gap above (`upper`) or below a row, for an "onto" the model refused.
  public func gap(around id: UUID, upper: Bool) -> Resolved? {
    if let at = roots.firstIndex(where: { $0.id == id }) {
      return resolve(parent: nil, index: upper ? at : at + 1)
    }
    for root in roots {
      if let at = root.children.firstIndex(of: id) {
        return resolve(parent: root.id, index: upper ? at : at + 1)
      }
    }
    return nil
  }

  private func childNode(_ id: UUID) -> Node? {
    roots.contains { $0.children.contains(id) } ? Node(id: id) : nil
  }
}

/// Edge auto-scroll while dragging in an outline (C27): how far to scroll per tick for a pointer
/// `y` points below the top of the visible list. Kept free of AppKit so it is unit-tested.
public enum OutlineAutoScroll {
  /// Points from an edge where scrolling starts.
  public static let edgeZone: Double = 36
  /// The fastest step per tick (points).
  public static let maxStep: Double = 16

  /// Negative = scroll up (pointer near or above the top edge), positive = down, 0 = the middle
  /// (or a list too short to have an edge zone). Grows the closer to / the further beyond the edge.
  public static func step(y: Double, height: Double) -> Double {
    guard height > 2 * edgeZone else { return 0 }
    if y < edgeZone { return -maxStep * min(1, (edgeZone - y) / edgeZone) }
    if y > height - edgeZone { return maxStep * min(1, (y - (height - edgeZone)) / edgeZone) }
    return 0
  }
}
