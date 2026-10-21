import Foundation

/// One transfer half as the pairing sees it (R-IMP-SALDO-2).
struct PairingHalf: Sendable {
  var date: Date
  /// The asset account (`name|currency`).
  var accountKey: String
  /// The MONEY_ON_THE_WAY leg.
  var transit: OriginalAmount
}

/// Pairs outgoing with incoming transfer halves (docs/import/saldo-format.md, "Transfer pairing").
///
/// A pair is allowed when the in-transit amount and currency are equal, the asset accounts
/// differ and the dates are at most `window` apart. Among the allowed pairs the matching pairs as
/// many halves as possible and, at that count, keeps the total time distance smallest; ties go to
/// the earliest halves.
///
/// Plain closest-first greedy is not enough: chains such as A → B → C booked within seconds with
/// the same amount make the closest candidate of B's incoming half B's own outgoing half, which is
/// not allowed, and greedy then strands both. Allowed pairs form small independent groups (same
/// amount, a few days), so an exact min-cost matching per group is cheap.
enum TransferPairing {
  static let defaultWindow: TimeInterval = 3 * 24 * 60 * 60

  /// Returns `(outgoing index, incoming index)` pairs, sorted by the outgoing index.
  static func pair(
    outgoing: [PairingHalf], incoming: [PairingHalf], window: TimeInterval = defaultWindow
  ) -> [(outgoing: Int, incoming: Int)] {
    var incomingByTransit: [OriginalAmount: [Int]] = [:]
    for (i, half) in incoming.enumerated() { incomingByTransit[half.transit, default: []].append(i) }

    // Allowed pairs, cost = time distance in milliseconds.
    var edges: [(out: Int, in: Int, cost: Int64)] = []
    for (o, out) in outgoing.enumerated() {
      for i in incomingByTransit[out.transit] ?? [] {
        let half = incoming[i]
        guard half.accountKey != out.accountKey else { continue }
        let distance = abs(half.date.timeIntervalSince(out.date))
        guard distance <= window else { continue }
        edges.append((o, i, Int64((distance * 1000).rounded())))
      }
    }

    // Independent groups: connected components over both sides (incoming offset by count).
    var parent = Array(0..<(outgoing.count + incoming.count))
    func find(_ x: Int) -> Int {
      var x = x
      while parent[x] != x {
        parent[x] = parent[parent[x]]
        x = parent[x]
      }
      return x
    }
    for edge in edges {
      let a = find(edge.out)
      let b = find(outgoing.count + edge.in)
      if a != b { parent[a] = b }
    }
    var groups: [Int: [(out: Int, in: Int, cost: Int64)]] = [:]
    for edge in edges { groups[find(edge.out), default: []].append(edge) }

    var result: [(outgoing: Int, incoming: Int)] = []
    for group in groups.values {
      result += matchGroup(group, outgoing: outgoing, incoming: incoming)
    }
    return result.sorted { $0.outgoing < $1.outgoing }
  }

  /// Min-cost maximum matching by successive shortest paths (Bellman–Ford on the residual graph).
  private static func matchGroup(
    _ edges: [(out: Int, in: Int, cost: Int64)], outgoing: [PairingHalf], incoming: [PairingHalf]
  ) -> [(outgoing: Int, incoming: Int)] {
    // Earliest halves first, so equal-cost choices fall to them.
    let outs = Set(edges.map(\.out)).sorted { (outgoing[$0].date, $0) < (outgoing[$1].date, $1) }
    let ins = Set(edges.map(\.in)).sorted { (incoming[$0].date, $0) < (incoming[$1].date, $1) }
    let outNode = Dictionary(uniqueKeysWithValues: outs.enumerated().map { ($1, $0 + 1) })
    let inNode = Dictionary(uniqueKeysWithValues: ins.enumerated().map { ($1, $0 + 1 + outs.count) })
    let source = 0
    let sink = outs.count + ins.count + 1
    let nodeCount = sink + 1

    struct Arc {
      var to: Int
      var capacity: Int
      var cost: Int64
    }
    var arcs: [Arc] = []
    var adjacency = Array(repeating: [Int](), count: nodeCount)
    func addArc(_ from: Int, _ to: Int, _ cost: Int64) {
      adjacency[from].append(arcs.count)
      arcs.append(Arc(to: to, capacity: 1, cost: cost))
      adjacency[to].append(arcs.count)
      arcs.append(Arc(to: from, capacity: 0, cost: -cost))
    }
    for o in outs { addArc(source, outNode[o]!, 0) }
    let sortedEdges = edges.sorted {
      (outNode[$0.out]!, inNode[$0.in]!) < (outNode[$1.out]!, inNode[$1.in]!)
    }
    for edge in sortedEdges { addArc(outNode[edge.out]!, inNode[edge.in]!, edge.cost) }
    for i in ins { addArc(inNode[i]!, sink, 0) }

    while true {
      var distance = Array(repeating: Int64.max, count: nodeCount)
      var via = Array(repeating: -1, count: nodeCount)
      distance[source] = 0
      for _ in 0..<nodeCount {
        var changed = false
        for node in 0..<nodeCount where distance[node] != .max {
          for a in adjacency[node] where arcs[a].capacity > 0 {
            let candidate = distance[node] + arcs[a].cost
            if candidate < distance[arcs[a].to] {
              distance[arcs[a].to] = candidate
              via[arcs[a].to] = a
              changed = true
            }
          }
        }
        if !changed { break }
      }
      guard distance[sink] != .max else { break }
      var node = sink
      while node != source {
        let a = via[node]
        arcs[a].capacity -= 1
        arcs[a ^ 1].capacity += 1
        node = arcs[a ^ 1].to
      }
    }

    var pairs: [(outgoing: Int, incoming: Int)] = []
    let outByNode = Dictionary(uniqueKeysWithValues: outNode.map { ($1, $0) })
    let inByNode = Dictionary(uniqueKeysWithValues: inNode.map { ($1, $0) })
    for (from, list) in adjacency.enumerated() {
      guard let o = outByNode[from] else { continue }
      for a in list where a % 2 == 0 && arcs[a].capacity == 0 {
        if let i = inByNode[arcs[a].to] { pairs.append((o, i)) }
      }
    }
    return pairs
  }
}
