import AbacusDomain
import AbacusFeatures
import SwiftUI

/// The Forecast tab of Upcoming (approved prototype `N5-forecast`, R-REC-13…15, 19, 20): series,
/// horizon and past-forecast pickers, the summary figures, the projection chart (with the overlay
/// of a past forecast and its gap), below-zero warnings, the gap split and the accuracy panel.
///
/// Self-contained: give it a `ForecastModel` the shell keeps (selections survive tab switches) or
/// just the dependencies. The display currency comes from the shell's switch (R-REC-14).
struct ForecastView: View {
  let displayCurrency: Currency
  @State private var model: ForecastModel

  /// With a model the shell keeps.
  init(model: ForecastModel, displayCurrency: Currency) {
    self.displayCurrency = displayCurrency
    _model = State(initialValue: model)
  }

  /// With its own model (`ForecastDependencies.live(database:refresher:)`).
  init(dependencies: ForecastDependencies, displayCurrency: Currency) {
    self.init(model: ForecastModel(dependencies: dependencies, displayCurrency: displayCurrency), displayCurrency: displayCurrency)
  }

  var body: some View {
    Group {
      switch model.phase {
      case .failed(let message):
        ContentUnavailableView {
          Label("Forecast unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try again") { Task { await model.load() } }
        }
      case .idle, .loading:
        ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForecastChartCard(model: model)
            if !model.warnings.isEmpty { ForecastWarningsBox(model: model) }
            if model.overlay != nil { ForecastGapCard(model: model) }
            ForecastAccuracyCard(model: model)
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .background(DashboardStyle.pageBackground)
    .onChange(of: displayCurrency, initial: true) { _, currency in model.displayCurrency = currency }
    .task { await model.load() }
  }
}

// MARK: - Chart card

private struct ForecastChartCard: View {
  @Bindable var model: ForecastModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      controls
      summary
      ForecastChart(model: model)
      legend
      Text(note)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if model.items.isEmpty {
        Text("No scheduled items yet: the line stays at today’s balance. Set up your bills in Upcoming.")
          .font(.callout)
      }
    }
    .dashboardCard()
  }

  private var controls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) {
        leftControls
        Spacer(minLength: 12)
        snapshotPicker
      }
      VStack(alignment: .leading, spacing: 10) {
        leftControls
        snapshotPicker
      }
    }
  }

  private var leftControls: some View {
    HStack(spacing: 12) {
      Picker("Show", selection: $model.series) {
        ForEach(model.seriesChoices, id: \.series) { choice in
          Text(choice.title).tag(choice.series)
        }
      }
      .pickerStyle(.menu)
      .fixedSize()
      .accessibilityLabel("Series")
      Picker("Horizon", selection: $model.horizonDays) {
        ForEach(ForecastEngine.horizonChoices, id: \.self) { days in
          Text("\(days) days").tag(days)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    }
  }

  private var snapshotPicker: some View {
    Picker(
      "Compare with a past forecast",
      selection: Binding(
        get: { model.selectedSnapshotID },
        set: { id in Task { await model.selectSnapshot(id) } })
    ) {
      Text(model.snapshots.isEmpty ? "None — no past forecasts yet" : "None — today’s forecast only")
        .tag(ForecastSnapshot.ID?.none)
      ForEach(model.snapshots) { snapshot in
        Text(model.label(snapshot)).tag(ForecastSnapshot.ID?.some(snapshot.id))
      }
    }
    .pickerStyle(.menu)
    .fixedSize()
    .disabled(model.snapshots.isEmpty)
  }

  private var summary: some View {
    let format = model.format
    let currency = model.seriesCurrency
    return HStack(alignment: .bottom, spacing: 28) {
      if let projection = model.projection, let now = projection.now, let end = projection.end {
        figure("Now", format.money(now.valueMinor, currency))
        figure("In \(model.horizonDays) days (\(format.day(end.day)))", format.money(end.valueMinor, currency))
        if let change = projection.changeMinor {
          figure("Change", format.signed(change, currency), color: change < 0 ? .red : .green)
        }
        if let lowest = projection.lowest {
          VStack(alignment: .leading, spacing: 2) {
            Text("Lowest point").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
              Text(format.money(lowest.valueMinor, currency))
                .font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(lowest.valueMinor < 0 ? Color.red : Color.primary)
              Text("· \(format.day(lowest.day))").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  private func figure(_ title: String, _ value: String, color: Color = .primary) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
    }
  }

  private var legend: some View {
    HStack(spacing: 16) {
      if let snapshot = model.selectedSnapshot, model.overlay != nil {
        swatch("Actual", color: ForecastStyle.actual, dash: [], width: 3)
        swatch("Forecast made \(model.format.day(snapshot.takenDay))", color: ForecastStyle.past, dash: [6, 4])
        swatch("Forecast made today", color: ForecastStyle.actual.opacity(0.6), dash: [2, 4])
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2).fill(ForecastStyle.gap.opacity(0.35)).frame(width: 14, height: 10)
          Text("Gap")
        }
      } else {
        swatch("Forecast made today (scheduled items only)", color: ForecastStyle.actual, dash: [6, 4])
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func swatch(_ title: String, color: Color, dash: [CGFloat], width: CGFloat = 2) -> some View {
    HStack(spacing: 6) {
      Path { path in
        path.move(to: CGPoint(x: 0, y: 1.5))
        path.addLine(to: CGPoint(x: 22, y: 1.5))
      }
      .stroke(color, style: StrokeStyle(lineWidth: width, dash: dash))
      .frame(width: 22, height: 3)
      Text(title)
    }
  }

  private var note: String {
    let format = model.format
    var text = "Today’s balance plus scheduled items only; everyday spending is not guessed."
    if case .netWorth = model.series {
      let asOf = model.ratesAsOf.map { "rates as of \(format.fullDay($0))" } ?? "no rates loaded yet"
      text += " Net worth is converted at today’s rates (\(asOf)) for the whole period; debts counted in net worth are held at today’s value."
      if let unconverted = model.projection?.unconverted, !unconverted.isEmpty {
        text += " Left out for lack of a rate: \(unconverted.map(\.rawValue).sorted().joined(separator: ", "))."
      }
    }
    if model.overlay != nil {
      text += " The comparison converts the actual line and the past forecast at the rates saved with the snapshot, so exchange-rate moves do not show up as a gap."
    }
    return text + " Values are end-of-day balances."
  }
}

// MARK: - Warnings

private struct ForecastWarningsBox: View {
  let model: ForecastModel

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(model.warnings) { warning in
          Text(model.text(warning)).fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color.yellow.opacity(0.14), in: .rect(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.55)))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isStaticText)
  }
}

// MARK: - Gap card

private struct ForecastGapCard: View {
  let model: ForecastModel

  var body: some View {
    let format = model.format
    let currency = model.overlay?.currency ?? model.seriesCurrency
    VStack(alignment: .leading, spacing: 10) {
      if let snapshot = model.selectedSnapshot {
        let ago = snapshot.daysAgo(today: model.today)
        Text("Forecast vs reality · made \(format.day(snapshot.takenDay)), \(ago == 1 ? "1 day" : "\(ago) days") ago")
          .dashboardCardTitle()
          .accessibilityAddTraits(.isHeader)
      }
      if let overlay = model.overlay, let gap = overlay.gapMinor, let split = overlay.split, let gapDay = overlay.gapDay {
        HStack(alignment: .bottom, spacing: 28) {
          figure(
            gapDay == model.today ? "Gap today (actual − forecast)" : "Gap on \(format.day(gapDay)) (actual − forecast)",
            format.signed(gap, currency), color: gap < 0 ? .red : .green)
          figure("Scheduled items paid differently", format.signed(split.scheduledMinor, currency))
          figure(
            "Everything else (unscheduled)", format.signed(split.otherMinor, currency),
            color: split.otherMinor < 0 ? .red : .green)
        }
        Text(gapNote(overlay, currency: currency))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        Text("No actual balances in the snapshot’s period yet.").font(.callout).foregroundStyle(.secondary)
      }
    }
    .dashboardCard()
  }

  private func gapNote(_ overlay: ForecastOverlay, currency: Currency) -> String {
    let format = model.format
    var note =
      "The “everything else” figure is the everyday spending and income the forecast ignores; it is what an “include average spending” option would have to cover."
    if let perDay = model.otherPerDayMinor { note += " Here it averages \(format.signed(perDay, currency)) per day." }
    if !overlay.unconverted.isEmpty {
      note += " Left out (no rate saved with the snapshot): \(overlay.unconverted.map(\.rawValue).sorted().joined(separator: ", "))."
    }
    return note
  }

  private func figure(_ title: String, _ value: String, color: Color = .primary) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
    }
  }
}
