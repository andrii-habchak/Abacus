import Foundation

/// Text layer of a PKO BP export: decoding and CSV records (R-IMP-PKO-1).
enum PKOText {
  /// PKO exports are Windows-1250. A file that is valid UTF-8 (re-saved by a spreadsheet) is
  /// read as UTF-8 instead: Polish letters in Windows-1250 are never valid UTF-8 sequences, and
  /// plain ASCII reads the same either way.
  static func decode(_ data: Data) -> String? {
    if let utf8 = String(data: data, encoding: .utf8) {
      return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
    }
    return String(data: data, encoding: .windowsCP1250)
  }

  /// One CSV record and the 1-based line it starts on.
  struct Record {
    var line: Int
    var fields: [String]
  }

  /// Comma-separated, optionally quoted fields (`""` escapes a quote); CRLF or LF line ends;
  /// line breaks inside quotes stay in the field. Blank lines are dropped.
  static func records(_ text: String) -> [Record] {
    var records: [Record] = []
    var fields: [String] = []
    var field = String.UnicodeScalarView()
    var inQuotes = false
    var line = 1
    var recordLine = 1
    var scalars = text.unicodeScalars.makeIterator()
    var pending: Unicode.Scalar? = nil

    func endField() {
      fields.append(String(field))
      field = String.UnicodeScalarView()
    }
    func endRecord() {
      endField()
      if !(fields.count == 1 && fields[0].isEmpty) {
        records.append(Record(line: recordLine, fields: fields))
      }
      fields = []
    }

    while let scalar = pending ?? scalars.next() {
      pending = nil
      if inQuotes {
        if scalar == "\"" {
          let next = scalars.next()
          if next == "\"" {
            field.append("\"")
          } else {
            inQuotes = false
            pending = next
          }
        } else {
          if scalar == "\n" { line += 1 }
          field.append(scalar)
        }
        continue
      }
      switch scalar {
      case "\"":
        inQuotes = true
      case ",":
        endField()
      case "\r":
        let next = scalars.next()
        if next != "\n" { pending = next }
        endRecord()
        line += 1
        recordLine = line
      case "\n":
        endRecord()
        line += 1
        recordLine = line
      default:
        field.append(scalar)
      }
    }
    if !field.isEmpty || !fields.isEmpty { endRecord() }
    return records
  }
}

extension String {
  /// Trimmed, with inner runs of whitespace (incl. no-break spaces) collapsed to one space.
  var pkoCollapsed: String {
    split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  var pkoTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
