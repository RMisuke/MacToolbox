import Combine
import Foundation
#if canImport(ToolboxCore)
import ToolboxCore
#endif

@MainActor
final class DoctorController: ObservableObject {
    @Published var checks: [EnvCheck] = []
    @Published var isChecking = false
    @Published var errorMessage: String?

    private var process: StreamingProcess?
    private var token = UUID()

    func check(tool: LoadedTool, values: [String: FieldValue]) {
        guard !isChecking else { return }
        guard let spec = tool.manifest.doctor else {
            errorMessage = "该工具没有声明环境检测命令"
            return
        }
        isChecking = true
        errorMessage = nil
        let currentToken = UUID()
        token = currentToken

        do {
            let configURL = try JobConfig.writeForDoctor(tool: tool, values: values)
            let context: [String: String] = [
                "toolDir": tool.directory.path,
                "jobDir": configURL.deletingLastPathComponent().path,
                "configFile": configURL.path
            ]
            let (command, arguments) = Template.expand(spec, context: context)

            let runner = StreamingProcess()
            runner.onLine = { [weak self] _, line in
                guard let self else { return }
                guard let data = line.data(using: .utf8),
                      let event = try? JSONDecoder().decode(JobEvent.self, from: data) else { return }
                if event.type == "env", let checks = event.checks {
                    self.checks = checks
                }
                if event.type == "error" {
                    self.errorMessage = event.message
                }
            }
            runner.onExit = { [weak self] _ in
                guard let self, self.token == currentToken else { return }
                self.isChecking = false
                if self.checks.isEmpty {
                    self.errorMessage = "环境检测没有返回结果"
                }
            }
            process = runner

            var environment = ToolEnvironment.base()
            // 启动时环境检测不主动读 Keychain，避免一打开 app 就弹钥匙串授权。
            // 任务真正启动时由 JobRunner 读取 Keychain。
            for field in tool.manifest.inputs where field.type == "secret" {
                let secret = values[field.key]?.stringValue ?? ""
                if !secret.isEmpty {
                    environment["MCT_SECRET_\(field.key)"] = secret
                }
            }

            try runner.start(
                command: command,
                arguments: arguments,
                workingDirectory: nil,
                environment: environment
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self, self.token == currentToken, self.isChecking else { return }
                self.process?.terminate()
                self.isChecking = false
                self.errorMessage = "环境检测超时"
            }
        } catch {
            isChecking = false
            errorMessage = error.localizedDescription
        }
    }
}
