import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The dashboard widgets in order (R-HOME-6): full-width widgets on a row of their own,
/// half-width ones two per row (`columns` 2) or one per row at narrow widths. Every widget has a
/// grip at its top edge to drag it onto another widget (it takes that widget's place); its
/// context menu moves it one place earlier or later and resets the layout.
struct DashboardWidgetGrid<Content: View>: View {
  let widgets: [DashboardWidget]
  let columns: Int
  let onMove: (DashboardWidget, DashboardWidget) -> Void
  /// -1 earlier, 1 later.
  let onStep: (DashboardWidget, Int) -> Void
  /// nil while the layout is the default one.
  let onReset: (() -> Void)?
  @ViewBuilder let content: (DashboardWidget) -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(DashboardLayout.rows(widgets, columns: columns), id: \.self) { row in
        HStack(alignment: .top, spacing: 16) {
          ForEach(row) { widget in
            cell(widget)
          }
          // A half-width widget alone on a wide row keeps its width (R-HOME-6).
          if columns > 1, row.count == 1, let only = row.first, !only.isFullWidth {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
          }
        }
      }
    }
  }

  private func cell(_ widget: DashboardWidget) -> some View {
    DashboardWidgetCell(
      widget: widget, isFirst: widget == widgets.first, isLast: widget == widgets.last,
      onDrop: { dragged in onMove(dragged, widget) }, onStep: { onStep(widget, $0) }, onReset: onReset
    ) {
      content(widget)
    }
    .frame(maxWidth: .infinity, alignment: .top)
  }
}

/// One widget with its drag grip, drop target and move menu.
private struct DashboardWidgetCell<Content: View>: View {
  let widget: DashboardWidget
  let isFirst: Bool
  let isLast: Bool
  let onDrop: (DashboardWidget) -> Void
  let onStep: (Int) -> Void
  let onReset: (() -> Void)?
  @ViewBuilder let content: () -> Content
  @State private var isTargeted = false
  @State private var gripHovered = false

  var body: some View {
    content()
      .overlay(alignment: .top) { grip }
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
        }
      }
      .dropDestination(for: String.self) { items, _ in
        guard let dragged = items.first.flatMap(DashboardWidget.init(rawValue:)), dragged != widget else {
          return false
        }
        onDrop(dragged)
        return true
      } isTargeted: { isTargeted = $0 }
      .contextMenu {
        Button("Move Earlier") { onStep(-1) }.disabled(isFirst)
        Button("Move Later") { onStep(1) }.disabled(isLast)
        if let onReset {
          Divider()
          Button("Reset Layout", action: onReset)
        }
      }
  }

  /// A small handle centred in the card's top padding; dragging it carries the widget's id.
  private var grip: some View {
    Image(systemName: "line.3.horizontal")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(gripHovered ? .secondary : .tertiary)
      .frame(width: 44, height: 14)
      .contentShape(.rect)
      .padding(.top, 2)
      .onHover { gripHovered = $0 }
      .draggable(widget.rawValue) {
        Label(widget.title, systemImage: "rectangle.on.rectangle")
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.regularMaterial, in: .rect(cornerRadius: 6))
      }
      .help("Drag to move \(widget.title)")
      .accessibilityLabel("Move \(widget.title)")
      .accessibilityHint("Drag onto another widget, or use the context menu")
  }
}
