import SwiftUI

struct BrewMaintenanceView: View {
    @ObservedObject var service: BrewService
    @State private var confirmCleanup = false
    @State private var confirmAutoremove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                environmentCard
                doctorCard
                maintenanceCard
                if let operation = service.operation, operation.title.contains("doctor") || operation.title.contains("missing") {
                    recentOutputCard(operation)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("运行 brew cleanup？", isPresented: $confirmCleanup) {
            Button("清理旧版本与缓存", role: .destructive) {
                service.cleanup(dryRun: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 Homebrew 的旧版本和下载缓存，可能释放较大空间；建议先运行「预演」。")
        }
        .confirmationDialog("运行 brew autoremove？", isPresented: $confirmAutoremove) {
            Button("移除不再需要的依赖", role: .destructive) {
                service.autoremove(dryRun: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会卸载不再被任何 formula 需要的依赖；建议先运行「预演」。")
        }
    }

    private var environmentCard: some View {
        SectionCard("环境") {
            Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 8) {
                GridRow {
                    label("版本")
                    Text(service.config.version.isEmpty ? "—" : service.config.version)
                        .font(.caption.monospaced())
                    label("Prefix")
                    Text(service.prefix.isEmpty ? "—" : service.prefix)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                GridRow {
                    label("API")
                    Text(service.config.apiDomain.isEmpty ? "官方默认" : service.config.apiDomain)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    label("Bottle")
                    Text(service.config.bottleDomain.isEmpty ? "官方默认" : service.config.bottleDomain)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                GridRow {
                    label("Brew Git")
                    Text(service.config.brewGitRemote.isEmpty ? "官方默认" : service.config.brewGitRemote)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    label("Core Git")
                    Text(service.config.coreGitRemote.isEmpty ? "官方默认" : service.config.coreGitRemote)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button {
                    Task { await service.refresh() }
                } label: {
                    Label("重新读取 brew config", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(service.isLoading || service.isRunning)
                Spacer()
                Text("当前 App 的 brew 环境；镜像在「镜像源」里切换。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var doctorCard: some View {
        SectionCard("自检与维护") {
            Text("brew doctor 会检查 Homebrew 安装、链接、权限、残留文件和 PATH。它不是修复命令；失败项需要逐条处理。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    service.runDoctor()
                } label: {
                    Label("运行 brew doctor", systemImage: "stethoscope")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!service.canOperate)

                Button {
                    service.runMissing()
                } label: {
                    Label("检查缺失依赖", systemImage: "exclamationmark.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(!service.canOperate)

                Button {
                    service.updateMetadata()
                } label: {
                    Label("brew update", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(!service.canOperate)

                Spacer()

                if let operation = service.operation, operation.state == .running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(operation.title) 运行中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var maintenanceCard: some View {
        SectionCard("清理与依赖") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button("cleanup 预演") { service.cleanup(dryRun: true) }
                        .buttonStyle(.bordered)
                    Button("运行 cleanup") { confirmCleanup = true }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    Button("autoremove 预演") { service.autoremove(dryRun: true) }
                        .buttonStyle(.bordered)
                    Button("运行 autoremove") { confirmAutoremove = true }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    Spacer()
                }
                .disabled(!service.canOperate)

                Text("预演使用 `brew cleanup -n` / `brew autoremove -n`，只输出将处理的项目，不修改系统。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recentOutputCard(_ operation: BrewOperation) -> some View {
        SectionCard("最近输出 · \(operation.title)") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(operation.lines.suffix(60)) { line in
                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.stream == "stderr" ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if operation.lines.isEmpty {
                    Text("没有输出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
