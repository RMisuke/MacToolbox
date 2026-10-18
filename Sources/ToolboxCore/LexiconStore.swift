import Combine
import Foundation

// MARK: - Profile model

public struct LexiconFingerprint: Codable {
    public var filenameKeywords: [String]?
    public var teacherNames: [String]?
    public var sampleTerms: [String]?
    public var chapterRange: String?

    public init(
        filenameKeywords: [String]? = nil,
        teacherNames: [String]? = nil,
        sampleTerms: [String]? = nil,
        chapterRange: String? = nil
    ) {
        self.filenameKeywords = filenameKeywords
        self.teacherNames = teacherNames
        self.sampleTerms = sampleTerms
        self.chapterRange = chapterRange
    }

    public var allFilenameKeywords: [String] { filenameKeywords ?? [] }
    public var allTeacherNames: [String] { teacherNames ?? [] }
}

public struct LexiconRule: Codable, Identifiable {
    public var from: String
    public var to: String
    public var source: String?
    public var confidence: Double?
    public var enabled: Bool?
    public var scope: String?

    public init(
        from: String,
        to: String,
        source: String? = "user",
        confidence: Double? = 1.0,
        enabled: Bool? = true,
        scope: String? = "global"
    ) {
        self.from = from
        self.to = to
        self.source = source
        self.confidence = confidence
        self.enabled = enabled
        self.scope = scope
    }

    public var id: String { from }
    public var isEnabled: Bool { enabled ?? true }
}

public struct LexiconProfile: Codable, Identifiable {
    public var schema: Int?
    public var id: String
    public var name: String
    public var version: Int?
    public var tool: String?
    public var fingerprint: LexiconFingerprint?
    public var hotwords: [String]?
    public var rules: [LexiconRule]?
    public var created: String?
    public var updated: String?

    public init(
        schema: Int? = 1,
        id: String,
        name: String,
        version: Int? = 1,
        tool: String? = nil,
        fingerprint: LexiconFingerprint? = nil,
        hotwords: [String]? = [],
        rules: [LexiconRule]? = [],
        created: String? = nil,
        updated: String? = nil
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.version = version
        self.tool = tool
        self.fingerprint = fingerprint
        self.hotwords = hotwords
        self.rules = rules
        self.created = created
        self.updated = updated
    }

    public var allHotwords: [String] { hotwords ?? [] }
    public var allRules: [LexiconRule] { (rules ?? []).filter { $0.isEnabled } }
    public var displayVersion: String { "v\(version ?? 1)" }
}

public struct LexiconMatch {
    public let profile: LexiconProfile
    public let score: Double
    public let reasons: [String]
}

public struct LexiconVersion: Identifiable {
    public var id: String { "\(profileID)-v\(number)" }
    public let profileID: String
    public let number: Int
    public let profile: LexiconProfile
    public let date: Date
}

public struct LexiconMergeSummary {
    public var addedHotwords = 0
    public var addedRules = 0
    public var skippedHotwords = 0
    public var skippedRules = 0
    public var conflicts: [String] = []
}

public enum LexiconStoreError: LocalizedError {
    case builtInReadOnly
    case invalidProfile
    case notFound

    public var errorDescription: String? {
        switch self {
        case .builtInReadOnly: return "内置词表只读；请先复制为我的词表"
        case .invalidProfile: return "词表格式无效"
        case .notFound: return "找不到词表"
        }
    }
}

// MARK: - Store

@MainActor
public final class LexiconStore: ObservableObject {
    @Published public private(set) var profiles: [LexiconProfile] = []
    @Published public private(set) var userProfileIDs: Set<String> = []

    public let userProfilesDirectory: URL
    private var toolDirectories: [URL]

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(toolDirectories: [URL]) {
        self.toolDirectories = toolDirectories
        userProfilesDirectory = ToolboxPaths.applicationSupport
            .appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: userProfilesDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()

        load()
    }

    // MARK: Loading

    /// 工具管理页新建/重扫工具后，让内置词表目录跟着更新。
    public func updateToolDirectories(_ directories: [URL]) {
        toolDirectories = directories
        load()
    }

    public func load() {
        var loadedByID: [String: LexiconProfile] = [:]
        var userIDs = Set<String>()

        for toolDirectory in toolDirectories {
            _ = readProfiles(
                from: toolDirectory.appendingPathComponent("profiles", isDirectory: true),
                into: &loadedByID
            )
        }
        userIDs = readProfiles(from: userProfilesDirectory, into: &loadedByID)

        profiles = loadedByID.values.sorted { $0.name < $1.name }
        userProfileIDs = userIDs
    }

    @discardableResult
    private func readProfiles(
        from directory: URL,
        into loaded: inout [String: LexiconProfile]
    ) -> Set<String> {
        var userIDs = Set<String>()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? decoder.decode(LexiconProfile.self, from: data) else {
                NSLog("LexiconStore: 跳过无效词表 \(file.path)")
                continue
            }
            loaded[profile.id] = profile
            userIDs.insert(profile.id)
        }
        return userIDs
    }

    // MARK: Queries

    public func profiles(for toolID: String) -> [LexiconProfile] {
        profiles.filter { $0.tool == nil || $0.tool == toolID }
    }

    public func profile(id: String) -> LexiconProfile? {
        profiles.first(where: { $0.id == id })
    }

    public func isUserProfile(_ id: String) -> Bool {
        userProfileIDs.contains(id)
    }

    public func match(path: String, toolID: String) -> LexiconMatch? {
        let haystack = path.lowercased()
        var best: LexiconMatch?

        for profile in profiles(for: toolID) {
            var score = 0.0
            var reasons: [String] = []

            let keywords = profile.fingerprint?.allFilenameKeywords ?? []
            if !keywords.isEmpty {
                let hits = keywords.filter { haystack.contains($0.lowercased()) }
                if !hits.isEmpty {
                    score += 0.6 * (Double(hits.count) / Double(keywords.count))
                    reasons.append("文件名/目录命中：" + hits.joined(separator: "、"))
                }
            }

            let teachers = profile.fingerprint?.allTeacherNames ?? []
            if !teachers.isEmpty {
                let hits = teachers.filter { haystack.contains($0.lowercased()) }
                if !hits.isEmpty {
                    score += 0.25
                    reasons.append("讲师名命中：" + hits.joined(separator: "、"))
                }
            }

            guard score >= 0.5 else { continue }
            if best == nil || score > best!.score {
                best = LexiconMatch(profile: profile, score: min(score, 1), reasons: reasons)
            }
        }
        return best
    }

    // MARK: Writing / versions

    public func profileFileURL(_ id: String) -> URL {
        userProfilesDirectory.appendingPathComponent("\(safeName(id)).json")
    }

    public func historyDirectory(_ id: String) -> URL {
        userProfilesDirectory
            .appendingPathComponent(".history", isDirectory: true)
            .appendingPathComponent(safeName(id), isDirectory: true)
    }

    @discardableResult
    public func save(_ profile: LexiconProfile) throws -> LexiconProfile {
        if !isUserProfile(profile.id) {
            // 同 ID 的内置词表不可覆盖；全新 ID 可以创建
            if profiles.contains(where: { $0.id == profile.id }) {
                throw LexiconStoreError.builtInReadOnly
            }
        }

        let fileURL = profileFileURL(profile.id)
        let current = (try? Data(contentsOf: fileURL)).flatMap {
            try? decoder.decode(LexiconProfile.self, from: $0)
        }

        if let current {
            archive(current)
        }

        var saved = profile
        let currentVersion = current?.version ?? 0
        saved.version = currentVersion + 1
        let now = Self.isoNow()
        if saved.created == nil {
            saved.created = current?.created ?? now
        }
        saved.updated = now

        let data = try encoder.encode(saved)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
        archive(saved)
        load()
        return saved
    }

    public func history(for id: String) -> [LexiconVersion] {
        let directory = historyDirectory(id)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var versions: [LexiconVersion] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? decoder.decode(LexiconProfile.self, from: data) else { continue }
            let number = Int(file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "v", with: "")) ?? (profile.version ?? 0)
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            versions.append(
                LexiconVersion(profileID: id, number: number, profile: profile, date: date)
            )
        }

        if versions.isEmpty, let current = profile(id: id), isUserProfile(id) {
            versions.append(
                LexiconVersion(
                    profileID: id,
                    number: current.version ?? 1,
                    profile: current,
                    date: Date()
                )
            )
        }
        return versions.sorted { $0.number > $1.number }
    }

    @discardableResult
    public func rollback(id: String, to version: Int) throws -> LexiconProfile {
        let versions = history(for: id)
        guard let target = versions.first(where: { $0.number == version }) else {
            throw LexiconStoreError.notFound
        }
        var profile = target.profile
        profile.id = id
        profile.updated = Self.isoNow()
        return try save(profile)
    }

    public func deleteUserProfile(_ id: String) throws {
        guard isUserProfile(id) else { throw LexiconStoreError.builtInReadOnly }
        try? FileManager.default.removeItem(at: profileFileURL(id))
        try? FileManager.default.removeItem(at: historyDirectory(id))
        load()
    }

    // MARK: Import / merge

    @discardableResult
    public func importLexicon(
        _ result: LexiconImportResult,
        into profileID: String?,
        name: String,
        toolID: String,
        overwriteRules: Bool
    ) throws -> (profile: LexiconProfile, summary: LexiconMergeSummary) {
        let base: LexiconProfile? = {
            guard let profileID,
                  isUserProfile(profileID),
                  let existing = profile(id: profileID) else { return nil }
            return existing
        }()

        var summary = LexiconMergeSummary()
        let now = Self.isoNow()
        var profile: LexiconProfile

        if let base {
            profile = base
            profile.name = name
        } else {
            let id = "user-" + safeName(name) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
            profile = LexiconProfile(
                id: id,
                name: name,
                version: 1,
                tool: toolID,
                fingerprint: result.profile?.fingerprint
                    ?? LexiconFingerprint(filenameKeywords: Self.keywords(from: name)),
                hotwords: [],
                rules: [],
                created: now,
                updated: now
            )
        }

        var hotwords = profile.allHotwords
        var seen = Set(hotwords.map { $0.lowercased() })
        for term in result.hotwords {
            let key = term.lowercased()
            if seen.insert(key).inserted {
                hotwords.append(term)
                summary.addedHotwords += 1
            } else {
                summary.skippedHotwords += 1
            }
        }

        var rules = profile.rules ?? []
        for rule in result.rules {
            if let index = rules.firstIndex(where: { $0.from == rule.from }) {
                if rules[index].to == rule.to {
                    if (rules[index].enabled ?? true) == false, (rule.enabled ?? true) {
                        rules[index].enabled = true
                        summary.addedRules += 1
                    } else {
                        summary.skippedRules += 1
                    }
                } else if overwriteRules {
                    rules[index] = rule
                    summary.addedRules += 1
                } else {
                    summary.conflicts.append("\(rule.from)：保留 \(rules[index].to)，跳过 \(rule.to)")
                    summary.skippedRules += 1
                }
            } else {
                rules.append(rule)
                summary.addedRules += 1
            }
        }

        let nameChanged = base?.name != name
        profile.hotwords = hotwords
        profile.rules = rules
        profile.tool = profile.tool ?? toolID
        if profile.fingerprint == nil {
            profile.fingerprint = result.profile?.fingerprint
                ?? LexiconFingerprint(filenameKeywords: Self.keywords(from: name))
        }
        profile.updated = now

        if base != nil,
           summary.addedHotwords + summary.addedRules == 0,
           !nameChanged {
            return (profile, summary)
        }

        let saved = try save(profile)
        return (saved, summary)
    }

    // MARK: Helpers

    private func archive(_ profile: LexiconProfile) {
        let directory = historyDirectory(profile.id)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("v\(profile.version ?? 1).json")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? encoder.encode(profile) else { return }
        try? data.write(to: file)
    }

    private func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "lexicon" : value
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func keywords(from name: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "·-_/（）()[]【】,，。"))
        let parts = name.components(separatedBy: separators)
        let stopwords: Set<String> = [
            "词表", "术语", "热词", "课程", "我的", "副本", "示例", "导入"
        ]
        var seen = Set<String>()
        var result: [String] = []
        for part in parts {
            let value = part.trimmingCharacters(in: .whitespaces)
            guard value.count >= 2 else { continue }
            let key = value.lowercased()
            guard !stopwords.contains(key) else { continue }
            if seen.insert(key).inserted {
                result.append(value)
            }
            if result.count >= 6 { break }
        }
        return result
    }
}
