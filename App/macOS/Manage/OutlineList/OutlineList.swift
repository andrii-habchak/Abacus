import AbacusFeatures
import AppKit
import SwiftUI

/// One row of an `OutlineList` (D55): its SwiftUI content, drag flags and children (one level
/// on the Categories and Accounts pages).
struct OutlineNode: Identifiable {
  let id: UUID
  /// Changes whenever the row's content changes; the list reloads only then.
  let signature: AnyHashable
  /// The row can be dragged.
  var canDrag = true
  /// A pinned row (the built-in "Uncategorised") is never dragged or dropped onto, and nothing
  /// lands above it.
  var isPinned = false
  var children: [OutlineNode] = []
  let content: AnyView

  init(
    id: UUID, signature: AnyHashable, canDrag: Bool = true, isPinned: Bool = false, children: [OutlineNode] = [],
    @ViewBuilder content: () -> some View
  ) {
    self.id = id
    self.signature = signature
    self.canDrag = canDrag && !isPinned
    self.isPinned = isPinned
    self.children = children
    self.content = AnyView(content())
  }

  /// What the list compares to decide on a reload.
  fileprivate var key: OutlineKey {
    OutlineKey(id: id, signature: signature, canDrag: canDrag, isPinned: isPinned, children: children.map(\.key))
  }
}

private struct OutlineKey: Hashable {
  let id: UUID
  let signature: AnyHashable
  let canDrag: Bool
  let isPinned: Bool
  let children: [OutlineKey]
}

/// An extra item of a row's context menu, above "Edit…" (C33).
struct OutlineMenuItem {
  let title: String
  var isEnabled = true
  let action: () -> Void
}

/// Carries a menu item's closure on `NSMenuItem.representedObject`.
private final class MenuAction: NSObject {
  let run: () -> Void
  init(_ run: @escaping () -> Void) { self.run = run }
}

/// A drop the list proposes: `target` nil = below the last row (top level, last). `moving` is
/// the dragged selection in list order (one row for a plain drag, C27).
struct OutlineDrop: Equatable {
  let moving: [UUID]
  let target: UUID?
  let position: CategoryDropPosition
}

/// Builds a one-level tree from flat rows whose children follow their parent (the order the
/// page models produce).
enum OutlineTree {
  static func nodes<Row>(_ rows: [Row], isChild: (Row) -> Bool, node: (Row, [OutlineNode]) -> OutlineNode)
    -> [OutlineNode]
  {
    var result: [(row: Row, children: [OutlineNode])] = []
    for row in rows {
      if isChild(row), !result.isEmpty {
        result[result.count - 1].children.append(node(row, []))
      } else {
        result.append((row, []))
      }
    }
    return result.map { node($0.row, $0.children) }
  }
}

/// The native outline list of the Categories and Accounts pages (D55): an `NSOutlineView` with
/// macOS drop feedback — a line between rows = reorder, a highlighted row = drop onto (nest) —
/// auto-scroll while dragging, selection, double-click / Return to edit and a context menu.
/// It never changes data itself: every proposal is asked of `canDrop`, and `onDrop` runs after
/// the drag session has ended.
struct OutlineList: NSViewRepresentable {
  let nodes: [OutlineNode]
  /// The selected rows (C27): several after Cmd / Shift click.
  let selection: Set<UUID>
  var rowHeight: CGFloat = 30
  let onSelect: (Set<UUID>) -> Void
  /// Double-click on a row, or "Edit…" in its context menu (the clicked row only), or Return with
  /// exactly one row selected. With several rows selected Return does nothing.
  let onActivate: (UUID) -> Void
  let canDrop: (OutlineDrop) -> Bool
  let onDrop: (OutlineDrop) -> Void
  /// Extra context-menu items for a row, listed before "Edit…"; none by default.
  var menuItems: (UUID) -> [OutlineMenuItem] = { _ in [] }

  func makeCoordinator() -> OutlineCoordinator { OutlineCoordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let outline = KeyOutlineView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.headerView = nil
    outline.style = .inset
    outline.rowHeight = rowHeight
    outline.usesAutomaticRowHeights = false
    outline.indentationPerLevel = 18
    outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    outline.backgroundColor = .clear
    // Finder-style (C27): plain click = one row, Cmd+click toggles the clicked row, Shift+click
    // selects from the anchor row to the clicked one in visible order (rows inside collapsed
    // groups are not visible, so they are not included; a selected group is dragged with its
    // children anyway). All native NSTableView behaviour.
    outline.allowsMultipleSelection = true
    outline.allowsEmptySelection = true
    outline.draggingDestinationFeedbackStyle = .regular
    outline.setDraggingSourceOperationMask(.move, forLocal: true)
    outline.setDraggingSourceOperationMask([], forLocal: false)
    outline.registerForDraggedTypes([.abacusOutlineRow])
    let coordinator = context.coordinator
    coordinator.parent = self
    outline.dataSource = coordinator
    outline.delegate = coordinator
    outline.target = coordinator
    outline.doubleAction = #selector(OutlineCoordinator.doubleClicked(_:))
    outline.onReturn = { [weak coordinator] outline in
      // One selected row only: with several, "edit" would be ambiguous.
      guard outline.selectedRowIndexes.count == 1 else { return }
      coordinator?.activate(row: outline.selectedRow, in: outline)
    }
    outline.menuForRow = { [weak coordinator] outline, row in coordinator?.menu(forRow: row, in: outline) }

    let scroll = NSScrollView()
    scroll.documentView = outline
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    coordinator.reload(nodes, in: outline)
    coordinator.applySelection(selection, in: outline)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let outline = scroll.documentView as? KeyOutlineView else { return }
    let coordinator = context.coordinator
    coordinator.parent = self
    if outline.rowHeight != rowHeight { outline.rowHeight = rowHeight }
    coordinator.reload(nodes, in: outline)
    coordinator.applySelection(selection, in: outline)
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: OutlineCoordinator) {
    coordinator.stopDragScrolling()
    guard let outline = scroll.documentView as? KeyOutlineView else { return }
    outline.dataSource = nil
    outline.delegate = nil
    outline.target = nil
    outline.onReturn = nil
    outline.menuForRow = nil
  }
}

extension NSPasteboard.PasteboardType {
  /// A row dragged inside an `OutlineList` (its id as text); other apps can't drop it.
  static let abacusOutlineRow = NSPasteboard.PasteboardType("io.github.andrii-habchak.abacus.outline-row")
}

/// An outline item: a reference type, because `NSOutlineView` tells items apart by identity.
final class OutlineItem: NSObject {
  let id: UUID
  let node: OutlineNode
  let children: [OutlineItem]

  init(_ node: OutlineNode) {
    id = node.id
    self.node = node
    children = node.children.map(OutlineItem.init)
  }
}

@MainActor
final class OutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
  var parent: OutlineList?
  private var roots: [OutlineItem] = []
  private var byID: [UUID: OutlineItem] = [:]
  private var keys: [OutlineKey]?
  /// Groups the user collapsed; kept across reloads.
  private var collapsed: Set<UUID> = []
  private var reloading = false
  private var applyingSelection = false
  /// The rows being dragged from this list, in list order.
  private var dragged: [UUID] = []
  private let scroller = DragScroller()
  /// The current tree, for mapping drop proposals (`OutlineDropResolver`).
  private var resolver = OutlineDropResolver(roots: [])

  // MARK: Data

  func reload(_ nodes: [OutlineNode], in outline: NSOutlineView) {
    let next = nodes.map(\.key)
    guard next != keys else { return }
    keys = next
    roots = nodes.map(OutlineItem.init)
    var index: [UUID: OutlineItem] = [:]
    for root in roots {
      index[root.id] = root
      for child in root.children { index[child.id] = child }
    }
    byID = index
    resolver = OutlineDropResolver(
      roots: roots.map { .init(id: $0.id, isPinned: $0.node.isPinned, children: $0.children.map(\.id)) })
    reloading = true
    outline.reloadData()
    for root in roots where !root.children.isEmpty && !collapsed.contains(root.id) {
      outline.expandItem(root)
    }
    reloading = false
    // The selection is applied again by the caller with the new items.
    applyingSelection = true
    outline.deselectAll(nil)
    applyingSelection = false
  }

  func applySelection(_ ids: Set<UUID>, in outline: NSOutlineView) {
    var rows = IndexSet()
    for id in ids {
      if let item = byID[id] {
        let row = outline.row(forItem: item)
        if row >= 0 { rows.insert(row) }
      }
    }
    guard rows != outline.selectedRowIndexes else { return }
    applyingSelection = true
    if rows.isEmpty {
      outline.deselectAll(nil)
    } else {
      outline.selectRowIndexes(rows, byExtendingSelection: false)
      // A single selection made elsewhere (new row, search) is scrolled into view.
      if rows.count == 1, let row = rows.first { outline.scrollRowToVisible(row) }
    }
    applyingSelection = false
  }

  private func item(_ any: Any?) -> OutlineItem? { any as? OutlineItem }

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let item = self.item(item) else { return roots.count }
    return item.children.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    let children = self.item(item)?.children ?? roots
    // AppKit asks only for valid indexes; a stale index still gets an item rather than a trap.
    return children.indices.contains(index) ? children[index] : (children.last ?? OutlineItem(OutlineNode(id: UUID(), signature: 0) { EmptyView() }))
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    !(self.item(item)?.children.isEmpty ?? true)
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let item = self.item(item) else { return nil }
    let cell =
      outlineView.makeView(withIdentifier: OutlineHostCell.identifier, owner: nil) as? OutlineHostCell
      ?? OutlineHostCell()
    cell.show(item.node.content)
    return cell
  }

  func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
    OutlineRowView()
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !applyingSelection, !reloading, let outline = notification.object as? NSOutlineView else { return }
    let ids = outline.selectedRowIndexes.compactMap { item(outline.item(atRow: $0))?.id }
    parent?.onSelect(Set(ids))
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard !reloading, let item = item(notification.userInfo?["NSObject"]) else { return }
    collapsed.insert(item.id)
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    guard !reloading, let item = item(notification.userInfo?["NSObject"]) else { return }
    collapsed.remove(item.id)
  }

  // MARK: Activation

  @objc func doubleClicked(_ sender: NSOutlineView) {
    activate(row: sender.clickedRow, in: sender)
  }

  func activate(row: Int, in outline: NSOutlineView) {
    guard row >= 0, let item = item(outline.item(atRow: row)) else { return }
    parent?.onActivate(item.id)
  }

  func menu(forRow row: Int, in outline: NSOutlineView) -> NSMenu? {
    guard row >= 0, let item = item(outline.item(atRow: row)) else { return nil }
    let menu = NSMenu()
    let extras = parent?.menuItems(item.id) ?? []
    for extra in extras {
      let entry = NSMenuItem(title: extra.title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
      entry.target = self
      entry.isEnabled = extra.isEnabled
      entry.representedObject = MenuAction(extra.action)
      menu.addItem(entry)
    }
    if !extras.isEmpty { menu.addItem(.separator()) }
    let edit = NSMenuItem(title: "Edit…", action: #selector(editFromMenu(_:)), keyEquivalent: "")
    edit.target = self
    edit.representedObject = item.id
    menu.addItem(edit)
    return menu
  }

  @objc private func runMenuAction(_ sender: NSMenuItem) {
    (sender.representedObject as? MenuAction)?.run()
  }

  @objc private func editFromMenu(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID, byID[id] != nil else { return }
    parent?.onActivate(id)
  }

  // MARK: Drag source

  func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
    guard let item = self.item(item), item.node.canDrag else { return nil }
    let board = NSPasteboardItem()
    board.setString(item.id.uuidString, forType: .abacusOutlineRow)
    return board
  }

  func outlineView(
    _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
    forItems draggedItems: [Any]
  ) {
    // Every selected row travels with the drag; list order, whatever the order AppKit lists them in.
    let ids = Set(draggedItems.compactMap { item($0)?.id })
    dragged = (0..<outlineView.numberOfRows).compactMap { row in
      item(outlineView.item(atRow: row)).flatMap { ids.contains($0.id) ? $0.id : nil }
    }
    scroller.start(outline: outlineView)
  }

  func outlineView(
    _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    dragged = []
    scroller.stop()
  }

  func stopDragScrolling() { scroller.stop() }

  // MARK: Drop target

  /// Applies a resolved proposal: asks the model, and moves the outline's feedback to where the
  /// drop really goes (`container` = the parent item of the gap).
  private func accept(
    _ resolved: OutlineDropResolver.Resolved?, moving: [UUID], container: OutlineItem?, proposedIndex: Int,
    in outline: NSOutlineView
  ) -> OutlineDrop? {
    guard let parent, let resolved else { return nil }
    let drop = OutlineDrop(moving: moving, target: resolved.target, position: resolved.position)
    guard parent.canDrop(drop) else { return nil }
    let index = resolved.index ?? NSOutlineViewDropOnItemIndex
    if index != proposedIndex { outline.setDropItem(container, dropChildIndex: index) }
    return drop
  }

  /// The allowed drop for a proposal: as proposed, or — when nesting isn't allowed there — the
  /// gap above or below the row under the pointer.
  private func allowedDrop(_ outline: NSOutlineView, _ info: any NSDraggingInfo, item proposed: Any?, index: Int)
    -> OutlineDrop?
  {
    guard !dragged.isEmpty, (info.draggingSource as? NSOutlineView) === outline else { return nil }
    let moving = dragged
    let item = self.item(proposed)
    let onto = index == NSOutlineViewDropOnItemIndex
    let resolved = resolver.resolve(parent: item?.id, index: onto ? nil : index)
    // Onto an empty parent the feedback stays on that row (the outline item itself).
    if let drop = accept(resolved, moving: moving, container: item, proposedIndex: index, in: outline) {
      return drop
    }
    // Onto refused (a parent with subcategories, a group onto a row…): the nearest gap instead.
    guard onto, let item else { return nil }
    let row = outline.row(forItem: item)
    guard row >= 0 else { return nil }
    let point = outline.convert(info.draggingLocation, from: nil)
    let upper = point.y < outline.rect(ofRow: row).midY
    let container = self.item(outline.parent(forItem: item))
    return accept(
      resolver.gap(around: item.id, upper: upper), moving: moving, container: container, proposedIndex: index,
      in: outline)
  }

  func outlineView(
    _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
    proposedChildIndex index: Int
  ) -> NSDragOperation {
    allowedDrop(outlineView, info, item: item, index: index) == nil ? [] : .move
  }

  func outlineView(
    _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int
  ) -> Bool {
    guard let drop = allowedDrop(outlineView, info, item: item, index: index) else { return false }
    // After the drag session has finished: the model reloads the list.
    DispatchQueue.main.async { [weak self] in self?.parent?.onDrop(drop) }
    return true
  }
}


/// Enter / Return activates the selected row; right-click shows the row's menu.
final class KeyOutlineView: NSOutlineView {
  var onReturn: ((NSOutlineView) -> Void)?
  var menuForRow: ((NSOutlineView, Int) -> NSMenu?)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0, let onReturn {
      onReturn(self)  // ignores several selected rows
      return
    }
    super.keyDown(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let row = self.row(at: convert(event.locationInWindow, from: nil))
    guard row >= 0 else { return nil }
    if !selectedRowIndexes.contains(row) {
      selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    return menuForRow?(self, row)
  }
}

/// A cell showing the row's SwiftUI content; clicks and drags go to the outline view.
final class OutlineHostCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("OutlineHostCell")
  private let host = PassthroughHostingView(rootView: AnyView(EmptyView()))

  init() {
    super.init(frame: .zero)
    identifier = Self.identifier
    host.sizingOptions = []
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
  }

  required init?(coder: NSCoder) { nil }

  func show(_ content: AnyView) {
    host.rootView = content
  }
}

final class PassthroughHostingView: NSHostingView<AnyView> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A light accent selection, so the row's own colours stay readable.
final class OutlineRowView: NSTableRowView {
  override var isEmphasized: Bool {
    get { false }
    set {}
  }

  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    let rect = bounds.insetBy(dx: 2, dy: 1)
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
  }
}


/// Scrolling while a drag is in flight (C27). During a drag session AppKit runs its own tracking
/// loop, so the mouse wheel / trackpad no longer reach the scroll view, and holding the pointer
/// near the edge only scrolls if the outline's own autoscroll fires. Two helpers, both limited to
/// the drag's lifetime: a local scroll-wheel monitor that scrolls the list under the pointer, and
/// a timer that scrolls when the pointer sits near the top / bottom edge. When the outline
/// scrolls by itself (its own autoscroll works) the edge timer steps aside so speeds don't add up.
@MainActor
final class DragScroller {
  private weak var outline: NSOutlineView?
  private var timer: Timer?
  private var monitor: Any?
  /// Where the clip view was after our last step; a different origin means someone else scrolled.
  private var expected: CGFloat?
  private var othersScroll = false

  func start(outline: NSOutlineView) {
    stop()
    self.outline = outline
    expected = nil
    othersScroll = false
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      let consumed = MainActor.assumeIsolated { self?.wheel(event) ?? false }
      return consumed ? nil : event
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    outline = nil
  }

  private func scrollBy(_ delta: CGFloat, in clip: NSClipView, scroll: NSScrollView, document: NSView) {
    let insets = clip.contentInsets
    let low = -insets.top
    let high = max(low, document.frame.height - clip.bounds.height + insets.bottom)
    let y = min(max(clip.bounds.origin.y + delta, low), high)
    guard y != clip.bounds.origin.y else { return }
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
    scroll.reflectScrolledClipView(clip)
  }

  private func tick() {
    guard let outline, let scroll = outline.enclosingScrollView, let window = outline.window else { return }
    let clip = scroll.contentView
    let origin = clip.bounds.origin.y
    if let expected, abs(expected - origin) > 0.5 { othersScroll = true }
    expected = origin
    guard !othersScroll else { return }
    let point = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    let bounds = clip.bounds
    guard point.x >= bounds.minX, point.x <= bounds.maxX else { return }
    // Position inside the visible area, 0 = its top edge (clip space is flipped for an outline).
    let y = clip.isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
    let step = OutlineAutoScroll.step(y: y, height: bounds.height)
    guard step != 0 else { return }
    scrollBy(clip.isFlipped ? step : -step, in: clip, scroll: scroll, document: outline)
    expected = clip.bounds.origin.y
  }

  private func wheel(_ event: NSEvent) -> Bool {
    guard let outline, let scroll = outline.enclosingScrollView, event.window === outline.window,
      scroll.convert(scroll.bounds, to: nil).contains(event.locationInWindow)
    else { return false }
    let clip = scroll.contentView
    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
    scrollBy(clip.isFlipped ? -delta : delta, in: clip, scroll: scroll, document: outline)
    expected = clip.bounds.origin.y
    return true
  }
}
