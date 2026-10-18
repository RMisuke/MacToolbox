import CoreFoundation
import Foundation

public struct LexiconImportResult {
    public var sourceName: String
    public var suggestedName: String
    public var hotwords: [String]
    public var rules: [LexiconRule]
    public var errors: [String]
    public var profile: LexiconProfile?
    public var duplicateHotwords: Int = 0
    public var duplicateRules: Int = 0

    public var total: Int { hotwords.count + rules.count }
}

public enum LexiconImportError: LocalizedError {
    case unsupported(String)
    case unreadable
    case empty
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            return "不支持的文件类型：.\(ext)；支持 txt / csv / json"
        case .unreadable:
            return "文件无法按 UTF-8 或 GB18030 读取"
        case .empty:
            return "没有解析到任何热词或规则"
        case .malformed(let detail):
            return "文件格式不正确：\(detail)"
        }
    }
}

public enum LexiconImportParser {
    public static func parse(url: URL) throws -> LexiconImportResult {
        let ext = url.pathExtension.lowercased()
        let suggested = url.deletingPathExtension().lastPathComponent
        let data = try Data(contentsOf: url)

        switch ext {
        case "txt", "text":
            let text = try decodeText(data)
            return parseText(text, sourceName: url.lastPathComponent, suggestedName: suggested)
        case "csv":
            let text = try decodeText(data)
            return try parseCSV(text, sourceName: url.lastPathComponent, suggestedName: suggested)
        case "json":
            return try parseJSON(data, sourceName: url.lastPathComponent, suggestedName: suggested)
        default:
            throw LexiconImportError.unsupported(ext.isEmpty ? "无扩展名" : ext)
        }
    }

    // MARK: - Text

    private static func decodeText(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text.replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        let gb = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gb) {
            return text
        }
        throw LexiconImportError.unreadable
    }

    private static func parseText(
        _ text: String,
        sourceName: String,
        suggestedName: String
    ) -> LexiconImportResult {
        var builder = Builder(sourceName: sourceName, suggestedName: suggestedName)
        let separators = ["=>", "->", "\t", "，", ","]

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }

            var consumed = false
            for separator in separators {
                if let range = line.range(of: separator) {
                    let from = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let to = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !from.isEmpty && !to.isEmpty && from != to {
                        builder.addRule(from: from, to: to, line: index + 1)
                        consumed = true
                        break
                    }
                }
            }
            if !consumed {
                builder.addHotword(line, line: index + 1)
            }
        }
        return builder.finish()
    }

    // MARK: - CSV

    private static func parseCSV(
        _ text: String,
        sourceName: String,
        suggestedName: String
    ) throws -> LexiconImportResult {
        let rows = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { parseCSVLine(String($0)) }
            .filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

        guard !rows.isEmpty else { throw LexiconImportError.empty }

        var builder = Builder(sourceName: sourceName, suggestedName: suggestedName)
        var startIndex = 0
        let first = rows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasHeader = first.contains {
            ["from", "to", "term", "hotword", "word", "错词", "正确", "热词", "术语"].contains($0)
        }

        var fromIndex: Int?
        var toIndex: Int?
        var termIndex: Int?

        if hasHeader {
            for (index, value) in first.enumerated() {
                if ["from", "错词", "错误", "原文"].contains(value) { fromIndex = index }
                if ["to", "正确", "修正", "标准"].contains(value) { toIndex = index }
                if ["term", "hotword", "word", "热词", "术语"].contains(value) { termIndex = index }
            }
            startIndex = 1
        }

        for rowIndex in startIndex..<rows.count {
            let row = rows[rowIndex]
            let line = rowIndex + 1

            if let fromIndex, let toIndex,
               row.indices.contains(fromIndex), row.indices.contains(toIndex) {
                let from = row[fromIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                let to = row[toIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !from.isEmpty && !to.isEmpty && from != to {
                    builder.addRule(from: from, to: to, line: line)
                    continue
                }
            }

            if let termIndex, row.indices.contains(termIndex) {
                let term = row[termIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !term.isEmpty {
                    builder.addHotword(term, line: line)
                    continue
                }
            }

            if row.count >= 2 {
                let from = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let to = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !from.isEmpty && !to.isEmpty && from != to {
                    builder.addRule(from: from, to: to, line: line)
                    continue
                }
            }

            if let term = row.first?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty {
                builder.addHotword(term, line: line)
            }
        }

        return builder.finish()
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let iterator = Array(line)
        var index = 0

        while index < iterator.count {
            let char = iterator[index]
            if char == "\"" {
                if inQuotes, index + 1 < iterator.count, iterator[index + 1] == "\"" {
                    current.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if char == ",", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }

    // MARK: - JSON

    private static func parseJSON(
        _ data: Data,
        sourceName: String,
        suggestedName: String
    ) throws -> LexiconImportResult {
        let data = stripBOM(data)
        let decoder = JSONDecoder()

        if let profile = try? decoder.decode(LexiconProfile.self, from: data) {
            var builder = Builder(
                sourceName: sourceName,
                suggestedName: profile.name.isEmpty ? suggestedName : profile.name
            )
            builder.profile = profile
            for (index, term) in profile.allHotwords.enumerated() {
                builder.addHotword(term, line: index + 1)
            }
            for (index, rule) in (profile.rules ?? []).enumerated() {
                builder.addRule(
                    from: rule.from,
                    to: rule.to,
                    line: index + 1,
                    source: rule.source,
                    confidence: rule.confidence,
                    enabled: rule.enabled
                )
            }
            return builder.finish()
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw LexiconImportError.malformed("JSON 无法解析")
        }

        var builder = Builder(sourceName: sourceName, suggestedName: suggestedName)
        builder.consumeJSON(json)
        return builder.finish()
    }

    private static func stripBOM(_ data: Data) -> Data {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return data.dropFirst(3)
        }
        return data
    }

    // MARK: - Builder

    private struct Builder {
        let sourceName: String
        let suggestedName: String
        var hotwords: [String] = []
        var rules: [LexiconRule] = []
        var errors: [String] = []
        var profile: LexiconProfile?

        private var hotwordSeen = Set<String>()
        private var ruleSeen: [String: String] = [:]
        private var duplicateHotwords = 0
        private var duplicateRules = 0

        init(sourceName: String, suggestedName: String) {
            self.sourceName = sourceName
            self.suggestedName = suggestedName
        }

        mutating func addHotword(_ raw: String, line: Int) {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return }
            if hotwords.count >= 1000 {
                if errors.count < 20 { errors.append("第 \(line) 行：热词超过 1000 个，已忽略") }
                return
            }
            if hotwordSeen.insert(term.lowercased()).inserted {
                hotwords.append(term)
            } else {
                duplicateHotwords += 1
            }
        }

        mutating func addRule(
            from rawFrom: String,
            to rawTo: String,
            line: Int,
            source: String? = "user",
            confidence: Double? = 1.0,
            enabled: Bool? = true
        ) {
            let from = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = rawTo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty else { return }
            if from == to { return }
            if rules.count >= 500 {
                if errors.count < 20 { errors.append("第 \(line) 行：规则超过 500 条，已忽略") }
                return
            }

            if let existing = ruleSeen[from] {
                duplicateRules += 1
                if existing != to, errors.count < 20 {
                    errors.append("第 \(line) 行：规则「\(from)」重复且目标不同（\(existing) / \(to)），保留第一条")
                }
                return
            }
            ruleSeen[from] = to
            rules.append(
                LexiconRule(
                    from: from,
                    to: to,
                    source: source ?? "user",
                    confidence: confidence ?? 1.0,
                    enabled: enabled ?? true,
                    scope: "global"
                )
            )
        }

        mutating func consumeJSON(_ json: Any) {
            if let array = json as? [String] {
                for (index, term) in array.enumerated() {
                    addHotword(term, line: index + 1)
                }
                return
            }

            if let array = json as? [[String: Any]] {
                for (index, item) in array.enumerated() {
                    if let from = item["from"] as? String, let to = item["to"] as? String {
                        addRule(
                            from: from,
                            to: to,
                            line: index + 1,
                            source: item["source"] as? String,
                            confidence: item["confidence"] as? Double,
                            enabled: item["enabled"] as? Bool
                        )
                    } else if let term = (item["term"] as? String) ?? (item["hotword"] as? String) {
                        addHotword(term, line: index + 1)
                    }
                }
                return
            }

            guard let dict = json as? [String: Any] else {
                errors.append("JSON 结构不支持；需要 Profile、字符串数组或 from/to")
                return
            }

            if let terms = (dict["hotwords"] as? [String]) ?? (dict["terms"] as? [String]) {
                for (index, term) in terms.enumerated() {
                    addHotword(term, line: index + 1)
                }
            }

            if let ruleArray = dict["rules"] as? [[String: Any]] {
                for (index, item) in ruleArray.enumerated() {
                    guard let from = item["from"] as? String,
                          let to = item["to"] as? String else { continue }
                    addRule(
                        from: from,
                        to: to,
                        line: index + 1,
                        source: item["source"] as? String,
                        confidence: item["confidence"] as? Double,
                        enabled: item["enabled"] as? Bool
                    )
                }
            } else if let ruleMap = dict["rules"] as? [String: String] {
                for (index, pair) in ruleMap.sorted(by: { $0.key < $1.key }).enumerated() {
                    addRule(from: pair.key, to: pair.value, line: index + 1)
                }
            } else if dict["hotwords"] == nil, dict["terms"] == nil, dict["rules"] == nil {
                // 纯 {from: to} 映射
                let stringMap = dict.compactMapValues { $0 as? String }
                if stringMap.count == dict.count, !stringMap.isEmpty {
                    for (index, pair) in stringMap.sorted(by: { $0.key < $1.key }).enumerated() {
                        addRule(from: pair.key, to: pair.value, line: index + 1)
                    }
                }
            }
        }

        func finish() -> LexiconImportResult {
            LexiconImportResult(
                sourceName: sourceName,
                suggestedName: suggestedName,
                hotwords: hotwords,
                rules: rules,
                errors: errors,
                profile: profile,
                duplicateHotwords: duplicateHotwords,
                duplicateRules: duplicateRules
            )
        }
    }
}
