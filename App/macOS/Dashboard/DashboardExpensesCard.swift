import AbacusDomain
import AbacusFeatures
import Charts
import SwiftUI

/// Monthly expenses (R-HOME-3): a donut by top-level category and a legend with amounts and
/// shares; parents expand to their subcategories. Clicking a slice or a legend row picks it,
/// which drills down to Transactions for that category and month. Hovering a slice only
/// highlights it: the pointer resting on the donut never switches screens (R-HOME-3).
struct DashboardExpensesCard: View {
  let expenses: DashboardExpenses
  let monthTitle: String
  let selected: CategoryKey?
  let onPick: (DashboardExpenses.Slice) -> Void
  /// The slice under the pointer: highlight only, never a drill-down.
  @State private var hovered: CategoryKey?
  @State private var expanded: Set<CategoryKey> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Monthly expenses").dashboardCardTitle()
        .accessibilityAddTraits(.isHeader)
      if expenses.isEmpty {
        Text("No expenses in \(monthTitle).")
          .foregroundStyle(.secondary)
      } else {
        HStack(alignment: .center, spacing: 24) {
          donut
          legend.frame(minWidth: 200)
        }
      }
    }
    .dashboardCard()
  }

  // MARK: Donut

  private var donut: some View {
    Chart(expenses.slices) { slice in
      SectorMark(
        angle: .value("Spent", double(slice.amount.decimal)),
        innerRadius: .ratio(0.64),
        outerRadius: .ratio(slice.id == selected || slice.id == hovered ? 1 : 0.9),
        angularInset: expenses.slices.count > 1 ? 1 : 0
      )
      // Full colour always: dimming the other slices after a pick (a drill-down leaves the
      // pick set) made them lighter than the legend and the Categories page (R-MGMT-7). The
      // picked or hovered slice stands out by its larger radius instead.
      .foregroundStyle(DashboardStyle.color(hex: slice.colorHex))
      .accessibilityLabel(slice.name)
      .accessibilityValue("\(slice.amountText), \(slice.percentText)")
    }
    .chartLegend(.hidden)
    // No `chartAngleSelection`: on macOS it follows the pointer, so a binding that drills down
    // navigated whenever the pointer rested on the donut (at launch, after a month change).
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle().fill(.clear).contentShape(.rect)
          .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered = slice(at: location, proxy: proxy, geometry: geometry)?.id
            case .ended: hovered = nil
            }
          }
          .onTapGesture { location in
            if let slice = slice(at: location, proxy: proxy, geometry: geometry), slice.drillsDown {
              onPick(slice)
            }
          }
      }
    }
    .help(hoveredHelp)
    .chartBackground { proxy in
      GeometryReader { geometry in
        if let anchor = proxy.plotFrame {
          let frame = geometry[anchor]
          VStack(spacing: 2) {
            Text("Spent").font(.caption).foregroundStyle(.secondary)
            Text(expenses.totalText).font(.headline).monospacedDigit()
          }
          .position(x: frame.midX, y: frame.midY)
        }
      }
    }
    .frame(width: 190, height: 190)
    .accessibilityLabel(expenses.chartLabel)
  }

  /// The slice under a point of the overlay, nil in the hole or outside the ring.
  private func slice(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> DashboardExpenses.Slice? {
    guard let anchor = proxy.plotFrame else { return nil }
    let frame = geometry[anchor]
    let point = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
    let radius = min(frame.width, frame.height) / 2
    let distance = hypot(point.x - frame.width / 2, point.y - frame.height / 2)
    guard distance >= radius * 0.6, distance <= radius else { return nil }
    guard let value = proxy.value(atAngle: proxy.angle(at: point), as: Double.self) else { return nil }
    return slice(atAngle: value)
  }

  private var hoveredHelp: String {
    guard let slice = expenses.slices.first(where: { $0.id == hovered }), slice.drillsDown else { return "" }
    return "Show \(slice.name) transactions for \(monthTitle)"
  }

  /// The slice holding a running total (the value an angle maps to).
  private func slice(atAngle value: Double) -> DashboardExpenses.Slice? {
    var running = 0.0
    for slice in expenses.slices {
      running += double(slice.amount.decimal)
      if value <= running { return slice }
    }
    return expenses.slices.last
  }

  // MARK: Legend

  private var legend: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(expenses.slices) { slice in
        legendRow(slice, indent: false)
        if expanded.contains(slice.id) {
          ForEach(slice.children) { child in legendRow(child, indent: true) }
        }
      }
    }
  }

  private func legendRow(_ slice: DashboardExpenses.Slice, indent: Bool) -> some View {
    HStack(spacing: 4) {
      if indent {
        Color.clear.frame(width: 22, height: 1)
      } else if slice.children.isEmpty {
        Color.clear.frame(width: 18, height: 1)
      } else {
        Button {
          withAnimation(.snappy) {
            if expanded.contains(slice.id) { expanded.remove(slice.id) } else { expanded.insert(slice.id) }
          }
        } label: {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(expanded.contains(slice.id) ? 90 : 0))
            .frame(width: 14, height: 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(expanded.contains(slice.id) ? "Hide subcategories" : "Show subcategories")
        .accessibilityLabel(expanded.contains(slice.id) ? "Hide subcategories of \(slice.name)" : "Show subcategories of \(slice.name)")
      }
      Button {
        onPick(slice)
      } label: {
        HStack(spacing: 8) {
          Circle()
            .fill(DashboardStyle.color(hex: slice.colorHex))
            .frame(width: indent ? 7 : 10, height: indent ? 7 : 10)
          Text(slice.name)
            .foregroundStyle(indent ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(slice.amountText)
            .foregroundStyle(.secondary)
          Text(slice.percentText)
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
        }
        .font(indent ? .caption : .callout)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, indent ? 4 : 6)
        .background(
          slice.id == selected ? Color.accentColor.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(!slice.drillsDown)
      .help(!slice.drillsDown ? "" : "Show \(slice.name) transactions for \(monthTitle)")
      .accessibilityAddTraits(slice.id == selected ? .isSelected : [])
    }
  }

  private func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
}

#Preview("Expenses, October") {
  @Previewable @State var model = DashboardModel(dependencies: .preview())
  VStack {
    if let expenses = model.expenses {
      DashboardExpensesCard(expenses: expenses, monthTitle: model.monthTitle, selected: model.selectedSlice) {
        model.select($0)
      }
    }
  }
  .padding()
  .frame(width: 560)
  .task { await model.load() }
}
