import Foundation

/// One CSV record and the 1-based line of the file where it starts.
struct CSVRecord: Equatable {
  var fields: [String]
  var line: Int
}

/// RFC 4180 reader for Saldo exports: comma-separated, `"`-quoted fields with `""` escapes,
/// LF or CRLF line ends, line breaks inside quoted fields (Saldo notes may contain them).
/// Works on UTF-8 bytes: the separators are ASCII, so a byte scan never splits a character.
enum CSVReader {
  private static let quote = UInt8(ascii: "\"")
  private static let comma = UInt8(ascii: ",")
  private static let cr = UInt8(ascii: "\r")
  private static let lf = UInt8(ascii: "\n")
  static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

  /// Drops a leading UTF-8 byte order mark.
  static func strippingBOM(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
    bytes.starts(with: utf8BOM) ? bytes.dropFirst(utf8BOM.count) : bytes[...]
  }

  /// Parses every record. Blank lines are skipped.
  static func records(_ bytes: ArraySlice<UInt8>) throws -> [CSVRecord] {
    var records: [CSVRecord] = []
    var fields: [String] = []
    var field: [UInt8] = []
    var inQuotes = false
    var fieldWasQuoted = false
    var line = 1
    var recordLine = 1

    func endField() {
      fields.append(String(decoding: field, as: UTF8.self))
      field.removeAll(keepingCapacity: true)
      fieldWasQuoted = false
    }

    func endRecord() {
      let isBlank = fields.isEmpty && field.isEmpty && !fieldWasQuoted
      if !isBlank {
        endField()
        records.append(CSVRecord(fields: fields, line: recordLine))
      }
      fields.removeAll(keepingCapacity: true)
      field.removeAll(keepingCapacity: true)
      fieldWasQuoted = false
    }

    var i = bytes.startIndex
    while i < bytes.endIndex {
      let byte = bytes[i]
      if inQuotes {
        if byte == quote {
          let next = bytes.index(after: i)
          if next < bytes.endIndex, bytes[next] == quote {
            field.append(quote)
            i = bytes.index(after: next)
            continue
          }
          inQuotes = false
        } else {
          if byte == lf { line += 1 }
          field.append(byte)
        }
        i = bytes.index(after: i)
        continue
      }
      switch byte {
      case quote:
        guard field.isEmpty, !fieldWasQuoted else {
          throw ImportError.malformed(line: line, reason: "Unexpected quote inside a field")
        }
        inQuotes = true
        fieldWasQuoted = true
      case comma:
        endField()
      case cr:
        let next = bytes.index(after: i)
        if next < bytes.endIndex, bytes[next] == lf { i = next }
        endRecord()
        line += 1
        recordLine = line
      case lf:
        endRecord()
        line += 1
        recordLine = line
      default:
        guard !fieldWasQuoted else {
          throw ImportError.malformed(line: line, reason: "Text after a closing quote")
        }
        field.append(byte)
      }
      i = bytes.index(after: i)
    }
    guard !inQuotes else {
      throw ImportError.malformed(line: recordLine, reason: "Unclosed quote")
    }
    endRecord()
    return records
  }
}
