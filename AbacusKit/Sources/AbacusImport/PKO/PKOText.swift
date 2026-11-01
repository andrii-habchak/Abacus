import Foundation

/// Text layer of a PKO BP export: decoding and CSV records (R-IMP-PKO-1).
enum PKOText {
  /// PKO exports are Windows-1250. A file that is valid UTF-8 (re-saved by a spreadsheet) is
  /// read as UTF-8 instead: Polish letters in Windows-1250 are never valid UTF-8 sequences, and
  /// plain ASCII reads the same either way.
  ///
  /// A file that is neither (C47: Windows-1250 mixed with UTF-8 lines, or holding a byte Windows-1250
  /// leaves undefined) is decoded line by line: a line with non-ASCII bytes that is valid UTF-8 is
  /// read as UTF-8, any other line as Windows-1250, and an undefined byte becomes U+FFFD for that
  /// byte only. One bad line no longer spoils or rejects the whole file. A U+FFFD already inside the
  /// source (EF BF BD) cannot be recovered here; rules treat it as a one-character wildcard
  /// (`TextFolding`).
  static func decode(_ data: Data) -> String? {
    if let utf8 = String(data: data, encoding: .utf8) {
      return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
    }
    if let cp1250 = String(data: data, encoding: .windowsCP1250), !isMixed(data) { return cp1250 }
    return decodeByLine(data)
  }

  /// Some line with non-ASCII bytes is valid UTF-8 while the file as a whole is not: mixed encodings.
  private static func isMixed(_ data: Data) -> Bool {
    lines(of: data).contains { line in
      line.contains { $0 >= 0x80 } && String(data: line, encoding: .utf8) != nil
    }
  }

  private static func decodeByLine(_ data: Data) -> String {
    var out = ""
    for line in lines(of: data) {
      if line.allSatisfy({ $0 < 0x80 }) {
        out += String(decoding: line, as: UTF8.self)
      } else if let utf8 = String(data: line, encoding: .utf8) {
        out += utf8
      } else if let cp1250 = String(data: line, encoding: .windowsCP1250) {
        out += cp1250
      } else {
        for byte in line {
          out += String(data: Data([byte]), encoding: .windowsCP1250) ?? "\u{FFFD}"
        }
      }
    }
    return out.hasPrefix("\u{FEFF}") ? String(out.dropFirst()) : out
  }

  /// The lines of `data`, each with its terminator (LF is one byte in both encodings).
  private static func lines(of data: Data) -> [Data] {
    var result: [Data] = []
    var start = data.startIndex
    for index in data.indices where data[index] == 0x0A {
      result.append(data[start...index])
      start = index + 1
    }
    if start < data.endIndex { result.append(data[start...]) }
    return result
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
