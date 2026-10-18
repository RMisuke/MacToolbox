import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct LexiconManagerSheet: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String?
    @State private var preview: LexiconImportResult?
    @State private var importName = ""
    @State private var overwriteRules = false
    @State private var errorMessage: String?
    @State private var lastSummary: LexiconMergeSummary?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(alignment: .top, spacing: 16) {
                profileList
                    .frame(width: 215)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let profile = selectedProfile {
                            profileDetail(profile)
                            if let lastSummary {
                                mergeSummary(lastSummary)
                            }
                        } else {
                            emptyState
                        }

                        if let preview {
                            importPreview(preview)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            HStack {
                Text("内置词表只读；导入/复制到用户词表后才会产生版本历史。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 920, height: 720)
        .onAppear(perform: selectInitial)
        .confirmationDialog("删除这个用户词表？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let profile = selectedProfile {
                    try? model.lexiconStore.deleteUserProfile(profile.id)
                    if model.values(for: tool)["termProfile"]?.stringValue == profile.id {
                        model.setValue(.string("auto"), for: "termProfile", tool: tool)
                    }
                    selectedID = model.lexiconProfiles(for: tool).first?.id
                    preview = nil
                    lastSummary = nil
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除当前版本的 JSON 与全部历史版本，不影响内置词表。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("词表管理")
                    .font(.title2.weight(.semibold))
                Text("导入 txt / csv / json；有变化时生成新版本，可回滚。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("词表")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(profiles.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(profiles) { profile in
                        let isUser = model.lexiconStore.isUserProfile(profile.id)
                        Button {
                            selectedID = profile.id
                            preview = nil
                            lastSummary = nil
                            errorMessage = nil
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: isUser ? "doc.text.fill" : "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(isUser ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text("\(profile.displayVersion) · \(profile.allHotwords.count) 热词 · \(profile.allRules.count) 规则")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if selectedID == profile.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(selectedID == profile.id ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                chooseImportFile()
            } label: {
                Label("导入词表…", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            .padding(.top, 4)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.lexiconStore.userProfilesDirectory])
            } label: {
                Label("打开词表目录", systemImage: "folder")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func profileDetail(_ profile: LexiconProfile) -> some View {
        let isUser = model.lexiconStore.isUserProfile(profile.id)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.title3.weight(.semibold))
                Text(profile.displayVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                Text(isUser ? "用户词表" : "内置只读")
                    .font(.caption2)
                    .foregroundStyle(isUser ? Color.accentColor : .secondary)
                Spacer()

                Button("导入词表…") { chooseImportFile() }
                    .controlSize(.small)
                if !isUser {
                    Button("复制为我的词表") { copyBuiltIn(profile) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                } else {
                    Button("删除", role: .destructive) { confirmDelete = true }
                        .controlSize(.small)
                }
            }

            if let fingerprint = profile.fingerprint {
                HStack(spacing: 6) {
                    Text("匹配：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text((fingerprint.allFilenameKeywords + fingerprint.allTeacherNames).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("热词（\(profile.allHotwords.count)）")
                    .font(.caption.weight(.semibold))
                Text(profile.allHotwords.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("规则（\(profile.allRules.count)）")
                    .font(.caption.weight(.semibold))
                if profile.allRules.isEmpty {
                    Text("没有规则")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(profile.allRules.prefix(40)) { rule in
                                HStack(spacing: 6) {
                                    Text(rule.from)
                                        .font(.system(size: 11, design: .monospaced))
                                    Text("→")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(rule.to)
                                        .font(.system(size: 11, design: .monospaced))
                                    Spacer()
                                    Text(rule.source ?? "user")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if profile.allRules.count > 40 {
                                Text("… 另有 \(profile.allRules.count - 40) 条")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                }
            }

            versionHistory(profile, isUser: isUser)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func versionHistory(_ profile: LexiconProfile, isUser: Bool) -> some View {
        let versions = model.lexiconStore.history(for: profile.id)

        VStack(alignment: .leading, spacing: 6) {
            Text("版本历史")
                .font(.caption.weight(.semibold))

            if !isUser {
                Text("内置词表没有版本历史；复制为我的词表后可导入/回滚。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if versions.isEmpty {
                Text("还没有历史版本")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(versions.prefix(12)) { version in
                            HStack(spacing: 8) {
                                Text("v\(version.number)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 34, alignment: .leading)
                                Text(dateText(version.date))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(version.profile.allHotwords.count) 热词 · \(version.profile.allRules.count) 规则")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if version.number == (profile.version ?? 1) {
                                    Text("当前")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                } else {
                                    Button("回滚") {
                                        do {
                                            try model.lexiconStore.rollback(
                                                id: profile.id,
                                                to: version.number
                                            )
                                            selectedID = profile.id
                                            errorMessage = nil
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
                                    }
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有词表")
                .font(.headline)
            Text("导入 txt / csv / json，或从内置示例复制一份。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("导入词表…") { chooseImportFile() }
        }
        .padding(14)
    }

    private func importPreview(_ result: LexiconImportResult) -> some View {
        let target = selectedProfile
        let isMerge = target.map { model.lexiconStore.isUserProfile($0.id) } ?? false

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("导入预览")
                    .font(.headline)
                Spacer()
                Button("取消") { preview = nil }
                    .controlSize(.small)
            }

            Text(result.sourceName)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("\(result.hotwords.count) 热词")
                Text("\(result.rules.count) 规则")
                if result.duplicateHotwords + result.duplicateRules > 0 {
                    Text("去重 \(result.duplicateHotwords + result.duplicateRules)")
                        .foregroundStyle(.secondary)
                }
                if !result.errors.isEmpty {
                    Text("\(result.errors.count) 个问题")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)

            if !result.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(result.errors.prefix(8).enumerated()), id: \.offset) { _, error in
                            Text("• " + error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxHeight: 70)
            }

            Text(isMerge
                 ? "将合并到「\(target?.name ?? "")」；有变化时生成新版本，已有规则默认保留。"
                 : "将新建一个用户词表。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("词表名称", text: $importName)
                .textFieldStyle(.roundedBorder)

            Toggle("覆盖同名但目标不同的规则", isOn: $overwriteRules)

            HStack {
                Spacer()
                Button("确认导入") {
                    guard let preview else { return }
                    do {
                        let targetID = isMerge ? target?.id : nil
                        let result = try model.lexiconStore.importLexicon(
                            preview,
                            into: targetID,
                            name: importName.trimmingCharacters(in: .whitespaces),
                            toolID: tool.id,
                            overwriteRules: overwriteRules
                        )
                        selectedID = result.profile.id
                        lastSummary = result.summary
                        self.preview = nil
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(importName.trimmingCharacters(in: .whitespaces).isEmpty || result.total == 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var profiles: [LexiconProfile] {
        model.lexiconProfiles(for: tool)
    }

    private var selectedProfile: LexiconProfile? {
        if let selectedID, let profile = model.lexiconStore.profile(id: selectedID) {
            return profile
        }
        return nil
    }

    private func selectInitial() {
        let current = model.values(for: tool)["termProfile"]?.stringValue ?? "auto"
        if current != "auto", current != "none", model.lexiconStore.profile(id: current) != nil {
            selectedID = current
        } else {
            selectedID = profiles.first?.id
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["txt", "csv", "json"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try LexiconImportParser.parse(url: url)
            preview = result
            let target = selectedProfile
            if let target, model.lexiconStore.isUserProfile(target.id) {
                importName = target.name
            } else if let target {
                importName = target.name + "（我的）"
            } else {
                importName = result.suggestedName
            }
            overwriteRules = false
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func copyBuiltIn(_ profile: LexiconProfile) {
        var copy = profile
        copy.id = "user-" + String(UUID().uuidString.prefix(8)).lowercased()
        copy.name = profile.name + "（我的）"
        copy.version = 1
        copy.created = nil
        copy.updated = nil
        do {
            let saved = try model.lexiconStore.save(copy)
            selectedID = saved.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeSummary(_ summary: LexiconMergeSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已导入")
                .font(.caption.weight(.semibold))
            Text("新增 \(summary.addedHotwords) 热词 / \(summary.addedRules) 规则；跳过 \(summary.skippedHotwords + summary.skippedRules)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !summary.conflicts.isEmpty {
                Text("冲突：" + summary.conflicts.prefix(3).joined(separator: "；"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.07)))
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
