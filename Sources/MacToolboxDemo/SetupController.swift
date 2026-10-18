import Combine
import Foundation
#if canImport(ToolboxCore)
import ToolboxCore
#endif

@MainActor
final class SetupController: ObservableObject {
    @Published var logs: [LogLine] = []
    @Published var checks: [EnvCheck] = []
    @Published var isRunning = false
    @Published var isFinished = false
    @Published var summary: String?
    @Published var errorMessage: String?

    private var process: StreamingProcess?

    func start(tool: LoadedTool, values: [String: FieldValue]) {
        guard !isRunning else { return }
        guard let spec = tool.manifest.setup else {
            errorMessage = "该工具没有声明修复命令"
            return
        }
        logs = []
        checks = []
        summary = nil
        errorMessage = nil
        isFinished = false
        isRunning = true

        do {
            let jobDir = try ToolboxPaths.newJobDirectory(toolID: "setup-\(tool.manifest.id)")
            let configURL = try JobConfig.write(tool: tool, values: values, jobDir: jobDir)
            let context: [String: String] = [
                "toolDir": tool.directory.path,
                "jobDir": jobDir.path,
                "configFile": configURL.path
            ]
            let (command, arguments) = Template.expand(spec, context: context)

            var environment = ToolEnvironment.base()
            environment["TOOLBOX_TOOL_DIR"] = tool.directory.path
            environment["TOOLBOX_JOB_DIR"] = jobDir.path
            environment["TOOLBOX_CONFIG"] = configURL.path

            let runner = StreamingProcess()
            runner.onLine = { [weak self] stream, line in
                guard let self else { return }
                if stream == .stderr {
                    self.append(level: "stderr", text: line)
                    return
                }
                guard let data = line.data(using: .utf8),
                      let event = try? JSONDecoder().decode(JobEvent.self, from: data) else {
                    self.append(level: "stdout", text: line)
                    return
                }
                switch event.type {
                case "log":
                    self.append(level: event.level ?? "info", text: event.message ?? "")
                case "env":
                    if let checks = event.checks { self.checks = checks }
                case "result":
                    self.summary = event.summary
                    if event.ok == false {
                        self.errorMessage = event.summary
                    }
                case "error":
                    self.errorMessage = event.message
                case "step":
                    if let title = event.title, let state = event.state {
                        self.append(level: "info", text: "\(title)：\(state)")
                    }
                default:
                    break
                }
            }
            runner.onExit = { [weak self] code in
                guard let self else { return }
                self.isRunning = false
                self.isFinished = true
                if code != 0 && self.errorMessage == nil {
                    self.errorMessage = "修复进程退出码 \(code)"
                }
            }
            process = runner

            append(level: "info", text: "启动环境修复…")
            try runner.start(
                command: command,
                arguments: arguments,
                workingDirectory: nil,
                environment: environment
            )
        } catch {
            isRunning = false
            isFinished = true
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        process?.terminate()
        isRunning = false
    }

    private func append(level: String, text: String) {
        logs.append(LogLine(level: level, text: text))
        if logs.count > 3000 {
            logs.removeFirst(logs.count - 3000)
        }
    }
}
