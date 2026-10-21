import AbacusFeatures
import SwiftUI

/// "Description · Category · Account · Amount" above the list.
struct TransactionColumnHeader: View {
  var body: some View {
    HStack(spacing: TxnMetrics.gap) {
      Color.clear.frame(width: TxnMetrics.tile, height: 1)
      TxnColumnsLayout {
        Text("Description")
        Text("Category")
        Text("Account")
        Text("Amount").frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }
}

/// "Wednesday, 21 October" with the day's net on the right.
struct TransactionDayHeader: View {
  let day: TransactionListContent.DaySection

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(day.title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary.opacity(0.85))
      Spacer()
      Text(day.netText)
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityLabel("Day net \(day.netText)")
    }
    .padding(.top, 8)
    .padding(.horizontal, TxnMetrics.horizontalPadding - 8)
  }
}

/// One transaction (R-LIST-4): category tile, description with badges, note · time, category,
/// account, amount in the account currency with "Charged …" or the received amount.
struct TransactionRowView: View {
  let row: TransactionListContent.Row

  var body: some View {
    HStack(spacing: TxnMetrics.gap) {
      tile
      TxnColumnsLayout {
        description
        Text(row.category)
          .foregroundStyle(.primary.opacity(0.8))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(row.account)
          .foregroundStyle(.primary.opacity(0.8))
          .lineLimit(1)
          .truncationMode(.middle)
        amount
      }
    }
    .font(.system(size: 13))
    .frame(minHeight: 40)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var tile: some View {
    Text(row.icon.symbol)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: TxnMetrics.tile, height: TxnMetrics.tile)
      .background(RoundedRectangle(cornerRadius: 7).fill(TxnPalette.tile(row.icon.colorHex)))
      .accessibilityHidden(true)
  }

  private var description: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(row.title)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)
        ForEach(row.badges, id: \.self) { badge in
          TransactionBadge(badge: badge)
        }
      }
      Text(row.subtitle)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  private var amount: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(row.amount)
        .fontWeight(row.tone == .transfer ? .medium : .semibold)
        .foregroundStyle(TxnPalette.amount(row.tone))
        .monospacedDigit()
      if let detail = row.amountDetail {
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// An attached record nested under its transaction (R-TX-6).
struct TransactionLineView: View {
  let line: TransactionListContent.Line

  var body: some View {
    HStack(spacing: TxnMetrics.gap) {
      Color.clear.frame(width: TxnMetrics.tile, height: 1)
      TxnColumnsLayout {
        HStack(spacing: 6) {
          Image(systemName: "arrow.turn.down.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
          Text(line.label).lineLimit(1)
        }
        Text(line.category).lineLimit(1)
        Color.clear.frame(height: 1)
        Text(line.amount)
          .fontWeight(.medium)
          .foregroundStyle(line.tone == .inflow ? TxnPalette.inflow : Color.primary.opacity(0.8))
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .font(.system(size: 12))
    .foregroundStyle(.primary.opacity(0.8))
    .accessibilityElement(children: .combine)
  }
}

/// Pending / Refund / event pill.
struct TransactionBadge: View {
  let badge: TransactionListContent.Badge

  var body: some View {
    let colors = TxnPalette.badge(badge.kind)
    Text(badge.label)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(colors.text)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Capsule().fill(colors.fill))
      .fixedSize()
  }
}
