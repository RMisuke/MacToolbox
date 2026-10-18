import Foundation

// MARK: - Packages

enum BrewPackageKind: String, Codable, CaseIterable, Hashable {
    case formula
    case cask

    var title: String {
        switch self {
        case .formula: return "Formula"
        case .cask: return "Cask"
        }
    }

    var icon: String {
        switch self {
        case .formula: return "shippingbox"
        case .cask: return "macwindow"
        }
    }
}

struct BrewPackage: Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(fullName)" }
    var kind: BrewPackageKind
    var name: String
    var fullName: String
    var displayName: String
    var description: String
    var homepage: String
    var tap: String
    var license: String
    var installedVersion: String
    var latestVersion: String
    var isOutdated: Bool
    var isPinned: Bool
    var installedOnRequest: Bool
    var isDeprecated: Bool
    var isDisabled: Bool
    var dependencies: [String]
    var dependents: [String]
    var caveats: String
    var installedAt: Date?

    var versionChange: String {
        guard isOutdated else { return installedVersion }
        return "\(installedVersion) → \(latestVersion)"
    }

    var isLeaf: Bool {
        kind == .formula && installedOnRequest && dependents.isEmpty
    }

    var dependencyCount: Int { dependencies.count }
    var dependentCount: Int { dependents.count }
}

struct BrewConfigSnapshot {
    var version: String = ""
    var prefix: String = ""
    var apiDomain: String = ""
    var bottleDomain: String = ""
    var brewGitRemote: String = ""
    var coreGitRemote: String = ""
    var caskGitRemote: String = ""
    var raw: [String: String] = [:]

    static func parse(_ text: String) -> BrewConfigSnapshot {
        var snapshot = BrewConfigSnapshot()
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            snapshot.raw[key] = value
            switch key {
            case "HOMEBREW_VERSION": snapshot.version = value
            case "HOMEBREW_PREFIX": snapshot.prefix = value
            case "HOMEBREW_API_DOMAIN": snapshot.apiDomain = value
            case "HOMEBREW_BOTTLE_DOMAIN": snapshot.bottleDomain = value
            case "HOMEBREW_BREW_GIT_REMOTE": snapshot.brewGitRemote = value
            case "HOMEBREW_CORE_GIT_REMOTE": snapshot.coreGitRemote = value
            case "HOMEBREW_CASK_GIT_REMOTE": snapshot.caskGitRemote = value
            default: break
            }
        }
        return snapshot
    }
}

// MARK: - Mirrors

struct BrewMirrorPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let apiDomain: String
    let bottleDomain: String
    let brewGitRemote: String
    let coreGitRemote: String
    let caskGitRemote: String

    static let all: [BrewMirrorPreset] = [
        BrewMirrorPreset(
            id: "official",
            name: "Homebrew 官方",
            note: "不设置镜像；使用 GitHub / formulae.brew.sh。",
            apiDomain: "",
            bottleDomain: "",
            brewGitRemote: "",
            coreGitRemote: "",
            caskGitRemote: ""
        ),
        BrewMirrorPreset(
            id: "tuna",
            name: "清华 TUNA",
            note: "国内常用；API、bottle、brew/core/cask git 全量镜像。",
            apiDomain: "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api",
            bottleDomain: "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles",
            brewGitRemote: "https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git",
            coreGitRemote: "https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git",
            caskGitRemote: "https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-cask.git"
        ),
        BrewMirrorPreset(
            id: "ustc",
            name: "中科大 USTC",
            note: "国内常用；适合教育网。",
            apiDomain: "https://mirrors.ustc.edu.cn/homebrew-bottles/api",
            bottleDomain: "https://mirrors.ustc.edu.cn/homebrew-bottles",
            brewGitRemote: "https://mirrors.ustc.edu.cn/brew.git",
            coreGitRemote: "https://mirrors.ustc.edu.cn/homebrew-core.git",
            caskGitRemote: "https://mirrors.ustc.edu.cn/homebrew-cask.git"
        ),
        BrewMirrorPreset(
            id: "aliyun",
            name: "阿里云",
            note: "国内常用；阿里云镜像。",
            apiDomain: "https://mirrors.aliyun.com/homebrew/homebrew-bottles/api",
            bottleDomain: "https://mirrors.aliyun.com/homebrew/homebrew-bottles",
            brewGitRemote: "https://mirrors.aliyun.com/homebrew/brew.git",
            coreGitRemote: "https://mirrors.aliyun.com/homebrew/homebrew-core.git",
            caskGitRemote: "https://mirrors.aliyun.com/homebrew/homebrew-cask.git"
        )
    ]

    static func preset(id: String) -> BrewMirrorPreset? {
        all.first(where: { $0.id == id })
    }
}

struct BrewMirrorSettings: Codable, Equatable {
    var presetID: String = "official"
    var apiDomain: String = ""
    var bottleDomain: String = ""
    var brewGitRemote: String = ""
    var coreGitRemote: String = ""
    var caskGitRemote: String = ""

    static let environmentKeys = [
        "HOMEBREW_API_DOMAIN",
        "HOMEBREW_BOTTLE_DOMAIN",
        "HOMEBREW_BREW_GIT_REMOTE",
        "HOMEBREW_CORE_GIT_REMOTE",
        "HOMEBREW_CASK_GIT_REMOTE"
    ]

    var environment: [String: String] {
        var result: [String: String] = [:]
        if !apiDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["HOMEBREW_API_DOMAIN"] = apiDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !bottleDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["HOMEBREW_BOTTLE_DOMAIN"] = bottleDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !brewGitRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["HOMEBREW_BREW_GIT_REMOTE"] = brewGitRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !coreGitRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["HOMEBREW_CORE_GIT_REMOTE"] = coreGitRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !caskGitRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["HOMEBREW_CASK_GIT_REMOTE"] = caskGitRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    var exportText: String {
        let env = environment
        let lines = BrewMirrorSettings.environmentKeys.map { key in
            if let value = env[key] {
                return "export \(key)=\"\(value)\""
            } else {
                return "unset \(key)"
            }
        }
        return lines.joined(separator: "\n")
    }

    mutating func apply(_ preset: BrewMirrorPreset) {
        presetID = preset.id
        apiDomain = preset.apiDomain
        bottleDomain = preset.bottleDomain
        brewGitRemote = preset.brewGitRemote
        coreGitRemote = preset.coreGitRemote
        caskGitRemote = preset.caskGitRemote
    }

    static func fromEnvironment() -> BrewMirrorSettings {
        let env = ProcessInfo.processInfo.environment
        var settings = BrewMirrorSettings()
        settings.apiDomain = env["HOMEBREW_API_DOMAIN"] ?? ""
        settings.bottleDomain = env["HOMEBREW_BOTTLE_DOMAIN"] ?? ""
        settings.brewGitRemote = env["HOMEBREW_BREW_GIT_REMOTE"] ?? ""
        settings.coreGitRemote = env["HOMEBREW_CORE_GIT_REMOTE"] ?? ""
        settings.caskGitRemote = env["HOMEBREW_CASK_GIT_REMOTE"] ?? ""
        settings.presetID = "custom"
        if settings.environment.isEmpty {
            settings.presetID = "official"
        } else if let matched = BrewMirrorPreset.all.first(where: { preset in
            preset.apiDomain == settings.apiDomain
                && preset.bottleDomain == settings.bottleDomain
                && preset.brewGitRemote == settings.brewGitRemote
                && preset.coreGitRemote == settings.coreGitRemote
                && preset.caskGitRemote == settings.caskGitRemote
        }) {
            settings.presetID = matched.id
        }
        return settings
    }
}

// MARK: - Operation

struct BrewLogLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let stream: String
    let date: Date
}

@MainActor
final class BrewOperation: ObservableObject, Identifiable {
    enum State: String {
        case running
        case succeeded
        case failed
        case cancelled
    }

    let id = UUID()
    let title: String
    let command: String
    @Published private(set) var state: State = .running
    @Published private(set) var lines: [BrewLogLine] = []
    @Published private(set) var exitCode: Int32?
    @Published private(set) var startedAt = Date()
    @Published private(set) var finishedAt: Date?

    init(title: String, command: String) {
        self.title = title
        self.command = command
    }

    func append(_ text: String, stream: String) {
        guard !text.isEmpty else { return }
        lines.append(BrewLogLine(text: text, stream: stream, date: Date()))
        if lines.count > 5000 {
            lines.removeFirst(lines.count - 5000)
        }
    }

    func finish(code: Int32, cancelled: Bool = false) {
        exitCode = code
        finishedAt = Date()
        if cancelled || state == .cancelled {
            state = .cancelled
        } else if code == 0 {
            state = .succeeded
        } else {
            state = .failed
        }
    }

    func markCancelled() {
        guard state == .running else { return }
        state = .cancelled
    }

    var stateText: String {
        switch state {
        case .running: return "后台运行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

enum BrewError: LocalizedError {
    case notFound
    case commandFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到 brew。请先安装 Homebrew：https://brew.sh"
        case .commandFailed(let message):
            return message
        case .timedOut(let command):
            return "命令超时：\(command)"
        }
    }
}
