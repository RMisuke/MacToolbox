import Combine
import Foundation
#if canImport(ToolboxCore)
import ToolboxCore
#endif

@MainActor
final class BrewService: ObservableObject {
    @Published private(set) var packages: [BrewPackage] = []
    @Published private(set) var config = BrewConfigSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var warningMessage: String?
    @Published private(set) var operation: BrewOperation?
    @Published var settings: BrewMirrorSettings

    private var process: StreamingProcess?
    private let settingsURL: URL
    private let brewPath: String?

    init() {
        brewPath = BrewRunner.findBrew()
        let url = ToolboxPaths.applicationSupport.appendingPathComponent("brew-settings.json")
        settingsURL = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(BrewMirrorSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .fromEnvironment()
        }
    }

    var brewVersion: String {
        config.version.isEmpty ? "Homebrew" : "Homebrew \(config.version)"
    }

    var prefix: String { config.prefix }
    var outdatedPackages: [BrewPackage] { packages.filter(\.isOutdated) }
    var outdatedCount: Int { outdatedPackages.count }
    var formulaCount: Int { packages.filter { $0.kind == .formula }.count }
    var caskCount: Int { packages.filter { $0.kind == .cask }.count }
    var pinnedCount: Int { packages.filter(\.isPinned).count }
    var leafCount: Int { packages.filter(\.isLeaf).count }

    var isRunning: Bool { operation?.state == .running }
    var canOperate: Bool { !isRunning && !isLoading }

    var environment: [String: String] {
        var env = ToolEnvironment.base()
        for key in BrewMirrorSettings.environmentKeys {
            env.removeValue(forKey: key)
        }
        for (key, value) in settings.environment {
            env[key] = value
        }
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_ASK"] = "1"
        env["HOMEBREW_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        return env
    }

    // MARK: - Loading

    func refresh() async {
        guard !isLoading else { return }
        guard let brewPath else {
            errorMessage = BrewError.notFound.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        warningMessage = nil
        defer { isLoading = false }

        do {
            let configResult = try await run(brewPath, ["config"], timeout: 30)
            guard configResult.status == 0 else {
                throw BrewError.commandFailed(
                    configResult.error.isEmpty ? "brew config 失败" : configResult.error
                )
            }
            config = BrewConfigSnapshot.parse(configResult.output)

            let infoResult = try await run(
                brewPath,
                ["info", "--json=v2", "--installed"],
                timeout: 120
            )
            guard infoResult.status == 0 else {
                throw BrewError.commandFailed(
                    infoResult.error.isEmpty ? "brew info 失败" : infoResult.error
                )
            }

            var outdatedData: Data?
            let outdatedResult = try? await run(
                brewPath,
                ["outdated", "--json=v2"],
                timeout: 120
            )
            if let outdatedResult {
                if outdatedResult.status == 0 {
                    outdatedData = outdatedResult.output.data(using: .utf8)
                } else if !outdatedResult.error.isEmpty {
                    warningMessage = "获取更新列表失败：\(outdatedResult.error.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            }

            packages = try BrewParser.packages(
                infoData: Data(infoResult.output.utf8),
                outdatedData: outdatedData
            )
            lastRefreshed = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> BrewCommandResult {
        try await BrewRunner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    func package(reference: String) -> BrewPackage? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }
        return packages.first { package in
            package.name == ref
                || package.fullName == ref
                || package.fullName.hasSuffix("/" + ref)
                || package.name.split(separator: "/").last.map(String.init) == ref
        }
    }

    // MARK: - Package actions

    func upgrade(_ package: BrewPackage) {
        runOperation(
            title: "升级 \(package.name)",
            arguments: ["upgrade", package.name]
        )
    }

    func upgrade(_ packages: [BrewPackage]) {
        guard !packages.isEmpty else { return }
        let names = packages.map(\.name)
        runOperation(
            title: names.count == 1 ? "升级 \(names[0])" : "升级 \(names.count) 个软件包",
            arguments: ["upgrade"] + names
        )
    }

    func upgradeAll() {
        let names = outdatedPackages.map(\.name)
        guard !names.isEmpty else { return }
        runOperation(
            title: "升级 \(names.count) 个可更新软件包",
            arguments: ["upgrade"] + names
        )
    }

    func uninstall(_ package: BrewPackage) {
        let args = package.kind == .cask
            ? ["uninstall", "--cask", package.name]
            : ["uninstall", package.name]
        runOperation(title: "卸载 \(package.name)", arguments: args)
    }

    func pin(_ package: BrewPackage) {
        guard package.kind == .formula else { return }
        runOperation(
            title: package.isPinned ? "取消固定 \(package.name)" : "固定 \(package.name)",
            arguments: [package.isPinned ? "unpin" : "pin", package.name]
        )
    }

    func updateMetadata() {
        runOperation(title: "brew update", arguments: ["update"])
    }

    func runDoctor() {
        runOperation(title: "brew doctor", arguments: ["doctor"], refreshAfter: false)
    }

    func cleanup(dryRun: Bool) {
        runOperation(
            title: dryRun ? "brew cleanup（预演）" : "brew cleanup",
            arguments: dryRun ? ["cleanup", "-n"] : ["cleanup"],
            refreshAfter: !dryRun
        )
    }

    func autoremove(dryRun: Bool) {
        runOperation(
            title: dryRun ? "brew autoremove（预演）" : "brew autoremove",
            arguments: dryRun ? ["autoremove", "-n"] : ["autoremove"],
            refreshAfter: !dryRun
        )
    }

    func runMissing() {
        runOperation(title: "brew missing", arguments: ["missing"], refreshAfter: false)
    }

    // MARK: - Generic operation

    func runOperation(title: String, arguments: [String], refreshAfter: Bool = true) {
        guard let brewPath else {
            errorMessage = BrewError.notFound.localizedDescription
            return
        }
        startOperation(
            title: title,
            executable: brewPath,
            arguments: arguments,
            refreshAfter: refreshAfter
        )
    }

    /// 把 brew 仓库的 origin 切到当前镜像选中的 Git remote。
    /// brew doctor 会检查 origin 与 HOMEBREW_BREW_GIT_REMOTE 是否一致。
    func syncBrewGitOrigin() {
        guard let brewPath else {
            errorMessage = BrewError.notFound.localizedDescription
            return
        }
        let repo = config.prefix.isEmpty ? URL(fileURLWithPath: brewPath).deletingLastPathComponent().deletingLastPathComponent().path : config.prefix
        let remote = settings.brewGitRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = remote.isEmpty ? "https://github.com/Homebrew/brew" : remote
        startOperation(
            title: "同步 brew git origin",
            executable: "/usr/bin/git",
            arguments: ["-C", repo, "remote", "set-url", "origin", target],
            refreshAfter: false
        )
    }

    private func startOperation(
        title: String,
        executable: String,
        arguments: [String],
        refreshAfter: Bool
    ) {
        guard operation?.state != .running else { return }
        let command = ([executable] + arguments).joined(separator: " ")
        let op = BrewOperation(title: title, command: command)
        operation = op
        errorMessage = nil

        let runner = StreamingProcess()
        process = runner
        runner.onLine = { [weak op] stream, line in
            let text = BrewRunner.stripANSI(line)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let name: String
            switch stream {
            case .stdout: name = "stdout"
            case .stderr: name = "stderr"
            }
            op?.append(text, stream: name)
        }
        runner.onExit = { [weak self, weak op] code in
            guard let self else { return }
            let cancelled = op?.state == .cancelled
            op?.finish(code: code, cancelled: cancelled)
            self.process = nil
            if code == 0, refreshAfter {
                Task { await self.refresh() }
            }
        }

        do {
            try runner.start(
                command: executable,
                arguments: arguments,
                workingDirectory: nil,
                environment: environment
            )
        } catch {
            op.append("启动命令失败：\(error.localizedDescription)", stream: "stderr")
            op.finish(code: -1)
            process = nil
        }
    }

    func cancelOperation() {
        guard let operation, operation.state == .running else { return }
        operation.markCancelled()
        process?.terminate(force: false)
    }

    func dismissOperation() {
        guard operation?.state != .running else { return }
        operation = nil
    }

    // MARK: - Settings

    func saveSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsURL)
    }

    func applyPreset(_ preset: BrewMirrorPreset) {
        settings.apply(preset)
        saveSettings()
    }

    func resetSettingsToEnvironment() {
        settings = .fromEnvironment()
        saveSettings()
    }
}
