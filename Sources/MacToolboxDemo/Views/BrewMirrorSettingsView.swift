import AppKit
import SwiftUI

struct BrewMirrorSettingsView: View {
    @ObservedObject var service: BrewService
    @State private var savedNotice: String?
    @State private var confirmSyncOrigin = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                presetCard
                endpointsCard
                effectiveCard
                noteCard
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("把 brew 仓库 origin 切到当前镜像？", isPresented: $confirmSyncOrigin) {
            Button("同步 git origin") { service.syncBrewGitOrigin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会执行 git -C <brew repo> remote set-url origin；这是 brew doctor 对镜像 origin 的建议操作。")
        }
    }

    private var presetCard: some View {
        SectionCard("镜像预设") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("", selection: Binding(
                        get: { service.settings.presetID },
                        set: { newValue in
                            if let preset = BrewMirrorPreset.preset(id: newValue) {
                                service.applyPreset(preset)
                            } else {
                                service.settings.presetID = "custom"
                                service.saveSettings()
                            }
                        }
                    )) {
                        ForEach(BrewMirrorPreset.all) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                        Text("自定义").tag("custom")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Spacer()
                    Button {
                        service.resetSettingsToEnvironment()
                        savedNotice = "已恢复为 App 启动时的环境变量"
                    } label: {
                        Label("恢复当前环境", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }

                if let preset = BrewMirrorPreset.preset(id: service.settings.presetID) {
                    Text(preset.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("自定义地址：修改下方字段后点「保存并刷新」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var endpointsCard: some View {
        SectionCard("地址") {
            VStack(alignment: .leading, spacing: 10) {
                endpointField("API Domain", text: $service.settings.apiDomain, placeholder: "https://…/api")
                endpointField("Bottle Domain", text: $service.settings.bottleDomain, placeholder: "https://…/homebrew-bottles")
                endpointField("Brew Git Remote", text: $service.settings.brewGitRemote, placeholder: "https://…/brew.git")
                endpointField("Core Git Remote", text: $service.settings.coreGitRemote, placeholder: "https://…/homebrew-core.git")
                endpointField("Cask Git Remote", text: $service.settings.caskGitRemote, placeholder: "https://…/homebrew-cask.git")

                HStack {
                    Button {
                        saveAndRefresh()
                    } label: {
                        Label("保存并刷新", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isLoading || service.isRunning)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(service.settings.exportText, forType: .string)
                        savedNotice = "已复制 shell export 片段"
                    } label: {
                        Label("复制 export", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        confirmSyncOrigin = true
                    } label: {
                        Label("同步 git origin", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.isRunning)

                    Spacer()
                    if let savedNotice {
                        Text(savedNotice)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private var effectiveCard: some View {
        SectionCard("当前生效（来自 brew config）") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                GridRow {
                    key("HOMEBREW_API_DOMAIN")
                    value(service.config.apiDomain)
                }
                GridRow {
                    key("HOMEBREW_BOTTLE_DOMAIN")
                    value(service.config.bottleDomain)
                }
                GridRow {
                    key("HOMEBREW_BREW_GIT_REMOTE")
                    value(service.config.brewGitRemote)
                }
                GridRow {
                    key("HOMEBREW_CORE_GIT_REMOTE")
                    value(service.config.coreGitRemote)
                }
                GridRow {
                    key("HOMEBREW_CASK_GIT_REMOTE")
                    value(service.config.caskGitRemote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button {
                    Task { await service.refresh() }
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(service.isLoading || service.isRunning)
                Spacer()
                Text(service.lastRefreshed?.formatted(date: .abbreviated, time: .standard) ?? "尚未刷新")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var noteCard: some View {
        SectionCard("说明") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• 镜像设置只注入本 App 启动的 brew 进程，不会修改 ~/.zshrc。")
                Text("• 「复制 export」得到的是 shell 片段；需要全局生效时自行粘贴到 shell 配置。")
                Text("• 切换镜像后首次 brew update / upgrade 可能会重新索引或下载，耗时取决于网络。\n• 如果 brew doctor 提示 git origin 与镜像不一致，用「同步 git origin」修正 brew 仓库的 remote。")
                Text("• 官方源不设置任何 HOMEBREW_* 镜像变量，会回退到 Homebrew 默认值。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func endpointField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 135, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func key(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func value(_ text: String) -> some View {
        Text(text.isEmpty ? "官方默认（未设置）" : text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .lineLimit(1)
    }

    private func saveAndRefresh() {
        if let preset = BrewMirrorPreset.preset(id: service.settings.presetID),
           preset.apiDomain != service.settings.apiDomain
            || preset.bottleDomain != service.settings.bottleDomain
            || preset.brewGitRemote != service.settings.brewGitRemote
            || preset.coreGitRemote != service.settings.coreGitRemote
            || preset.caskGitRemote != service.settings.caskGitRemote {
            service.settings.presetID = "custom"
        }
        service.saveSettings()
        savedNotice = "已保存；正在刷新 brew config"
        Task { await service.refresh() }
    }
}
