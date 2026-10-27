import AbacusDomain
import Foundation
import SQLiteData

/// Gives categories, accounts and events a palette colour (R-MGMT-7, D45).
///
/// Runs inside the writes that create rows (repository saves, import commit, default and sample
/// seeding), so every creation path ends up coloured, and once in migration "v4: colours" with
/// `replacingGrey` for rows created before. Reads and writes only the columns it needs with plain
/// SQL, not the `@Table` types, so the migration keeps working when the entities change later.
///
/// Distinct where it matters: a category avoids its siblings' colours (same kind and parent; a
/// subcategory also its parent's), an account the other accounts', an event the other events'.
public enum ColorFill {
  /// Fills every table. Without `replacingGrey` only rows without a valid colour change.
  public static func fillAll(_ db: Database, replacingGrey: Bool = false) throws {
    var generator = SystemRandomNumberGenerator()
    try fillAll(db, replacingGrey: replacingGrey, using: &generator)
  }

  public static func fillAll(
    _ db: Database, replacingGrey: Bool, using generator: inout some RandomNumberGenerator
  ) throws {
    try fillCategories(db, replacingGrey: replacingGrey, using: &generator)
    try fillFlat(table: "accounts", db, replacingGrey: replacingGrey, using: &generator)
    try fillFlat(table: "events", db, replacingGrey: replacingGrey, using: &generator)
  }

  public static func fillCategories(_ db: Database) throws {
    var generator = SystemRandomNumberGenerator()
    try fillCategories(db, replacingGrey: false, using: &generator)
  }

  public static func fillAccounts(_ db: Database) throws {
    var generator = SystemRandomNumberGenerator()
    try fillFlat(table: "accounts", db, replacingGrey: false, using: &generator)
  }

  public static func fillEvents(_ db: Database) throws {
    var generator = SystemRandomNumberGenerator()
    try fillFlat(table: "events", db, replacingGrey: false, using: &generator)
  }

  private static func needsColor(_ hex: String?, replacingGrey: Bool) -> Bool {
    replacingGrey ? ColorPalette.needsColor(hex) : ColorPalette.rgb(hex) == nil
  }

  /// `columns` of every row of `table` in `order`, as text (NULL → nil). Ids are read and
  /// written back exactly as stored.
  private static func rows(
    _ db: Database, table: String, columns: [String], order: String
  ) throws -> [[String?]] {
    // One text value per row: each column as "1<value>" or "0" for NULL, joined by a tab.
    let fields = columns.map { #"coalesce('1' || "\#($0)", '0')"# }.joined(separator: " || char(9) || ")
    let lines = try String.fetchAll(db, sql: #"SELECT \#(fields) FROM "\#(table)" ORDER BY \#(order)"#)
    return lines.map { line in
      line.split(separator: "\t", omittingEmptySubsequences: false).map { field in
        field.first == "1" ? String(field.dropFirst()) : nil
      }
    }
  }

  private static func setColor(_ color: String, table: String, id: String, _ db: Database) throws {
    try db.execute(sql: #"UPDATE "\#(table)" SET "colorHex" = ? WHERE "id" = ?"#, arguments: [color, id])
  }

  /// Parents first, so a subcategory sees its parent's new colour.
  static func fillCategories(
    _ db: Database, replacingGrey: Bool, using generator: inout some RandomNumberGenerator
  ) throws {
    let rows = try rows(
      db, table: "categories", columns: ["id", "kind", "parentID", "colorHex"],
      order: #""parentID" IS NOT NULL, "kind", "position", "name""#)
    guard rows.contains(where: { needsColor($0[3], replacingGrey: replacingGrey) }) else { return }
    var colorByID: [String: String] = [:]
    var usedByGroup: [String: [String?]] = [:]
    func group(_ row: [String?]) -> String { "\(row[1] ?? "")|\(row[2] ?? "")" }
    for row in rows where !needsColor(row[3], replacingGrey: replacingGrey) {
      colorByID[row[0] ?? ""] = row[3]
      usedByGroup[group(row), default: []].append(row[3])
    }
    for row in rows where needsColor(row[3], replacingGrey: replacingGrey) {
      guard let id = row[0] else { continue }
      var avoid = usedByGroup[group(row)] ?? []
      if let parentID = row[2] { avoid.append(colorByID[parentID]) }
      let color = ColorPalette.pick(avoiding: avoid, using: &generator)
      try setColor(color, table: "categories", id: id, db)
      colorByID[id] = color
      usedByGroup[group(row), default: []].append(color)
    }
  }

  /// Accounts or events: one group, every row avoids the others.
  static func fillFlat(
    table: String, _ db: Database, replacingGrey: Bool, using generator: inout some RandomNumberGenerator
  ) throws {
    let rows = try rows(db, table: table, columns: ["id", "colorHex"], order: #""name", "id""#)
    var used = rows.map { $0[1] }.filter { !needsColor($0, replacingGrey: replacingGrey) }
    for row in rows where needsColor(row[1], replacingGrey: replacingGrey) {
      guard let id = row[0] else { continue }
      let color = ColorPalette.pick(avoiding: used, using: &generator)
      try setColor(color, table: table, id: id, db)
      used.append(color)
    }
  }
}
