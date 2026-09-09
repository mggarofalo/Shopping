import Foundation

enum CatalogCSVError: Error, Equatable, LocalizedError {
    case unreadableText
    case malformedQuote(line: Int)
    case missingColumns([String])
    case duplicateIdentity(line: Int)
    case invalidRow(line: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadableText: "The file isn’t valid UTF-8 text."
        case .malformedQuote(let line): "Line \(line) has an unmatched quote."
        case .missingColumns(let columns): "Missing required columns: \(columns.joined(separator: ", "))."
        case .duplicateIdentity(let line): "Line \(line) repeats an earlier source_id and item_id."
        case .invalidRow(let line, let reason): "Line \(line): \(reason)"
        }
    }
}

enum CatalogCSVParser {
    static func parse(_ data: Data) throws -> [CatalogImportRow] {
        guard var text = String(data: data, encoding: .utf8) else { throw CatalogCSVError.unreadableText }
        if text.first == "\u{feff}" { text.removeFirst() }
        let records = try records(in: text)
        guard let header = records.first else {
            throw CatalogCSVError.missingColumns(["source_id", "item_id", "name"])
        }
        let names = header.values.map(normalizedHeader)
        let required = ["source_id", "item_id", "name"]
        let missing = required.filter { !names.contains($0) }
        guard missing.isEmpty else { throw CatalogCSVError.missingColumns(missing) }
        guard Set(names).count == names.count else {
            throw CatalogCSVError.invalidRow(line: header.line, reason: "Column names must be unique.")
        }
        let columns = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
        var identities: Set<String> = []
        var rows: [CatalogImportRow] = []
        for record in records.dropFirst() where !record.values.allSatisfy({ trimmed($0).isEmpty }) {
            func value(_ name: String) -> String {
                guard let index = columns[name], index < record.values.count else { return "" }
                return trimmed(record.values[index])
            }
            let sourceID = value("source_id")
            let itemID = value("item_id")
            let name = value("name")
            let identity = "\(sourceID)\u{0}\(itemID)"
            let parseError: String? = {
                if record.values.count > names.count { return "Too many columns." }
                if sourceID.isEmpty { return "source_id is required." }
                if itemID.isEmpty { return "item_id is required." }
                if name.isEmpty { return "name is required." }
                if identities.contains(identity) { return "This source_id and item_id repeat an earlier row." }
                return nil
            }()
            if parseError == nil { identities.insert(identity) }
            let category = value("category")
            var seenStores: Set<String> = []
            let stores = value("stores").split(separator: ";").map { trimmed(String($0)) }.filter {
                !$0.isEmpty && seenStores.insert(CatalogProjection.normalizedName($0)).inserted
            }
            rows.append(CatalogImportRow(
                line: record.line,
                sourceID: sourceID,
                itemID: itemID,
                name: name,
                notes: value("notes"),
                categoryName: category.isEmpty ? nil : category,
                storeNames: stores,
                parseError: parseError
            ))
        }
        return rows
    }

    private struct Record {
        let line: Int
        let values: [String]
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedHeader(_ value: String) -> String {
        trimmed(value).lowercased()
    }

    private static func records(in text: String) throws -> [Record] {
        var records: [Record] = []
        var values: [String] = []
        var field = ""
        var quoted = false
        var line = 1
        var recordLine = 1
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = text.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == ",", !quoted {
                values.append(field)
                field = ""
            } else if character == "\n", !quoted {
                values.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                records.append(Record(line: recordLine, values: values))
                values = []
                field = ""
                line += 1
                recordLine = line
            } else {
                field.append(character)
                if character == "\n" { line += 1 }
            }
            index = next
        }
        guard !quoted else { throw CatalogCSVError.malformedQuote(line: recordLine) }
        if !field.isEmpty || !values.isEmpty {
            values.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            records.append(Record(line: recordLine, values: values))
        }
        return records
    }
}
