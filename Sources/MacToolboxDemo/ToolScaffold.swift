import AppKit
import Foundation
#if canImport(ToolboxCore)
import ToolboxCore
#endif

enum ToolScaffoldError: LocalizedError {
    case invalidID
    case missingScript
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidID:
            return "工具 ID 只能使用小写字母、数字、点、下划线和短横线，且不能以符号开头"
        case .missingScript:
            return "找不到 new_tool.py；请重新构建 App，或从仓库 scripts/ 运行"
        case .failed(let message):
            return message
        }
    }
}

/// 调用仓库里的 `scripts/new_tool.py` 创建工具，避免 Swift/Python 两套模板漂移。
enum ToolScaffold {
    static func create(
        id: String,
        name: String,
        category: String,
        summary: String
    ) async throws -> URL {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedID.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw ToolScaffoldError.invalidID
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ToolScaffoldError.failed("工具名称不能为空")
        }

        let toolsDirectory = ToolboxPaths.applicationSupport.appendingPathComponent("Tools", isDirectory: true)
        let destination = toolsDirectory.appendingPathComponent("\(trimmedID).toolbox", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolScaffoldError.failed("工具已存在：\(destination.path)")
        }

        return try await Task.detached(priority: .userInitiated) {
            guard let script = scriptURL() else { throw ToolScaffoldError.missingScript }
            try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3", script.path,
                "--id", trimmedID,
                "--name", trimmedName,
                "--category", category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "示例" : category.trimmingCharacters(in: .whitespacesAndNewlines),
                "--summary", summary.trimmingCharacters(in: .whitespacesAndNewlines),
                "--tools-dir", toolsDirectory.path
            ]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw ToolScaffoldError.failed("无法启动 Python：\(error.localizedDescription)")
            }
            process.waitUntilExit()

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ToolScaffoldError.failed(detail.isEmpty ? output : detail)
            }
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw ToolScaffoldError.failed("脚本执行成功，但没有找到生成目录：\(destination.path)")
            }
            return destination
        }.value
    }

    static func guideURL() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("新工具开发指南.md"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/新工具开发指南.md")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    private static func scriptURL() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Scripts/new_tool.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scripts/new_tool.py"),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("scripts/new_tool.py")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
