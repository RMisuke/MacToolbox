import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

private enum BrewTab: String, CaseIterable, Identifiable {
    case packages
    case updates
    case dependencies
    case maintenance
    case mirrors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .packages: return "软件包"
        case .updates: return "可更新"
        case .dependencies: return "依赖关系"
        case .maintenance: return "维护"
        case .mirrors: return "镜像源"
        }
    }

    var icon: String {
        switch self {
        case .packages: return "shippingbox"
        case .updates: return "arrow.down.circle"
        case .dependencies: return "point.3.connected.trianglepath.dotted"
        case .maintenance: return "stethoscope"
        case .mirrors: return "network"
        }
    }
}

private enum BrewFilter: String, CaseIterable, Identifiable {
    case all
    case updates
    case formula
    case cask
    case pinned
    case leaves

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .updates: return "可更新"
        case .formula: return "Formula"
        case .cask: return "Cask"
        case .pinned: return "已固定"
        case .leaves: return "顶层包"
        }
    }
}

enum BrewPackageAction {
    case upgrade
    case pin
    case uninstall
}

struct BrewManagerView: View {
    @EnvironmentObject private var brew: BrewService
    @State private var tab: BrewTab = .packages
    @State private var searchText = ""
    @State private var filter: BrewFilter = .all
    @State private var selectedPackage: BrewPackage?
    @State private var selectedUpdateIDs = Set<String>()
    @State private var dependencyRootID: String?
    @State private var showUpgradeAll = false
    @State private var pendingPackageAction: (BrewPackage, BrewPackageAction)?
    @State private var showBrewConsole = false

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            if let operation = brew.operation {
                operationBar(operation)
            }
            Divider()
            content
                .id(tab)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await brew.refresh()
        }
        .onChange(of: brew.operation?.id) { _, newValue in
            if newValue != nil {
                showBrewConsole = true
            }
        }
        .sheet(item: $selectedPackage) { package in
            BrewPackageDetailView(
                package: package,
                service: brew,
                onAction: { action in
                    selectedPackage = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        perform(action, on: package)
                    }
                }
            )
        }
        .sheet(isPresented: $showBrewConsole) {
            if let operation = brew.operation {
                BrewConsoleView(
                    operation: operation,
                    onCancel: { brew.cancelOperation() },
                    onHide: { showBrewConsole = false },
                    onClose: {
                        showBrewConsole = false
                        brew.dismissOperation()
                    }
                )
            }
        }
        .confirmationDialog("升级全部可更新软件包？", isPresented: $showUpgradeAll) {
            Button("开始升级", role: .destructive) {
                brew.upgradeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会运行 brew upgrade，可能耗时较长；过程中可取消。")
        }
        .confirmationDialog(
            "卸载 \(pendingPackageAction?.0.name ?? "")？",
            isPresented: Binding(
                get: { pendingPackageAction?.1 == .uninstall },
                set: { if !$0 { pendingPackageAction = nil } }
            )
        ) {
            Button("卸载", role: .destructive) {
                if let pending = pendingPackageAction {
                    brew.uninstall(pending.0)
                }
                pendingPackageAction = nil
            }
            Button("取消", role: .cancel) { pendingPackageAction = nil }
        } message: {
            Text("卸载可能影响依赖它的软件包；Homebrew 会提示确认。")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Homebrew 管理器")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .layoutPriority(1)
                        Text(brew.config.version.isEmpty ? "—" : brew.config.version)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.1)))
                    }
                    Text(brew.prefix.isEmpty ? "读取本机 Homebrew 状态…" : brew.prefix)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        Task { await brew.refresh() }
                    } label: {
                        if brew.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(brew.isLoading || brew.isRunning)

                    Button {
                        brew.updateMetadata()
                    } label: {
                        Label("brew update", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!brew.canOperate)

                    if brew.outdatedCount > 0 {
                        Button {
                            showUpgradeAll = true
                        } label: {
                            Label("全部升级", systemImage: "arrow.up.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!brew.canOperate)
                    }
                }
            }

            HStack(spacing: 8) {
                BrewStatChip(icon: "shippingbox", text: "\(brew.formulaCount) formula", color: .blue)
                BrewStatChip(icon: "macwindow", text: "\(brew.caskCount) cask", color: .purple)
                BrewStatChip(icon: "arrow.down.circle", text: "\(brew.outdatedCount) 可更新", color: brew.outdatedCount > 0 ? Color.orange : Color.secondary)
                BrewStatChip(icon: "pin", text: "\(brew.pinnedCount) 固定", color: .teal)
                BrewStatChip(icon: "leaf", text: "\(brew.leafCount) 顶层", color: .green)
                Spacer()
                if let last = brew.lastRefreshed {
                    Text("上次刷新 \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let error = brew.errorMessage {
                messageBanner(text: error, color: .red, icon: "exclamationmark.octagon.fill") {
                    Task { await brew.refresh() }
                }
            }
            if let warning = brew.warningMessage {
                messageBanner(text: warning, color: .orange, icon: "exclamationmark.triangle.fill", action: nil)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(BrewTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.caption)
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                        if item == .updates, brew.outdatedCount > 0 {
                            Text("\(brew.outdatedCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.orange))
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tab == item ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if brew.isLoading && brew.packages.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取 brew info / outdated…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if brew.packages.isEmpty {
            ContentUnavailableView(
                "没有读到 Homebrew 软件包",
                systemImage: "shippingbox",
                description: Text(brew.errorMessage ?? "请确认 Homebrew 已安装，然后点刷新。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch tab {
            case .packages:
                packagesView
            case .updates:
                updatesView
            case .dependencies:
                dependenciesView
            case .maintenance:
                BrewMaintenanceView(service: brew)
            case .mirrors:
                BrewMirrorSettingsView(service: brew)
            }
        }
    }

    // MARK: - Packages

    private var packagesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchField(text: $searchText, placeholder: "搜索包名 / 描述")
                Picker("", selection: $filter) {
                    ForEach(BrewFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                Spacer()
                Text("\(filteredPackages.count) 个")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPackages) { package in
                        BrewPackageRow(package: package) {
                            selectedPackage = package
                        }
                        .contextMenu {
                            if package.isOutdated {
                                Button("升级") { perform(.upgrade, on: package) }
                            }
                            if package.kind == .formula {
                                Button(package.isPinned ? "取消固定" : "固定版本") {
                                    perform(.pin, on: package)
                                }
                            }
                            Button("复制包名") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(package.name, forType: .string)
                            }
                            Button("打开主页") {
                                if let url = URL(string: package.homepage) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Divider()
                            Button("卸载…", role: .destructive) {
                                pendingPackageAction = (package, .uninstall)
                            }
                        }
                        Divider().padding(.leading, 70)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 20)
            }
        }
    }

    private var filteredPackages: [BrewPackage] {
        var result = brew.packages
        switch filter {
        case .all: break
        case .updates: result = result.filter(\.isOutdated)
        case .formula: result = result.filter { $0.kind == .formula }
        case .cask: result = result.filter { $0.kind == .cask }
        case .pinned: result = result.filter(\.isPinned)
        case .leaves: result = result.filter(\.isLeaf)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        return result.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
                || $0.dependencies.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    // MARK: - Updates

    private var updatesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("可更新软件包")
                        .font(.headline)
                    Text("勾选后升级；升级过程会打开 brew 控制台。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if selectedUpdateIDs.count == brew.outdatedPackages.count {
                        selectedUpdateIDs.removeAll()
                    } else {
                        selectedUpdateIDs = Set(brew.outdatedPackages.map(\.id))
                    }
                } label: {
                    Text(selectedUpdateIDs.count == brew.outdatedPackages.count ? "取消全选" : "全选")
                }
                .buttonStyle(.bordered)
                .disabled(brew.outdatedPackages.isEmpty)

                Button {
                    let selected = brew.outdatedPackages.filter { selectedUpdateIDs.contains($0.id) }
                    brew.upgrade(selected)
                    selectedUpdateIDs.removeAll()
                } label: {
                    Label("升级选中", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedUpdateIDs.isEmpty || !brew.canOperate)

                Button {
                    showUpgradeAll = true
                } label: {
                    Label("全部升级", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!brew.canOperate)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)

            if brew.outdatedPackages.isEmpty {
                ContentUnavailableView(
                    "全部是最新版本",
                    systemImage: "checkmark.seal",
                    description: Text("brew outdated 没有返回可更新项。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(brew.outdatedPackages) { package in
                            HStack(spacing: 12) {
                                Button {
                                    if selectedUpdateIDs.contains(package.id) {
                                        selectedUpdateIDs.remove(package.id)
                                    } else {
                                        selectedUpdateIDs.insert(package.id)
                                    }
                                } label: {
                                    Image(systemName: selectedUpdateIDs.contains(package.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedUpdateIDs.contains(package.id) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)

                                BrewPackageIcon(package: package, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(package.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(package.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(package.installedVersion)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(package.latestVersion)
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(.orange)
                                Button("升级") { brew.upgrade(package) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(!brew.canOperate)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedPackage = package }
                            Divider().padding(.leading, 60)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    // MARK: - Dependencies

    private var dependenciesView: some View {
        let root = dependencyRoot
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("选择软件包")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { root?.id ?? "" },
                    set: { dependencyRootID = $0 }
                )) {
                    ForEach(brew.packages) { package in
                        Text("\(package.displayName)  ·  \(package.kind.title)").tag(package.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
                Spacer()
                if let root {
                    Text("\(root.dependencies.count) 个直接依赖 · \(root.dependents.count) 个被依赖")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)

            if let root {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BrewDependencyGraphCard(package: root)

                        HStack(alignment: .top, spacing: 14) {
                            BrewDependencyColumn(
                                title: "依赖",
                                icon: "arrow.right.circle",
                                color: .blue,
                                references: root.dependencies,
                                service: brew
                            ) { dependencyRootID = $0.id }

                            BrewDependencyColumn(
                                title: "被依赖",
                                icon: "arrow.left.circle",
                                color: .orange,
                                references: root.dependents,
                                service: brew
                            ) { dependencyRootID = $0.id }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var dependencyRoot: BrewPackage? {
        if let dependencyRootID,
           let package = brew.packages.first(where: { $0.id == dependencyRootID }) {
            return package
        }
        return brew.packages.first
    }

    // MARK: - Actions

    private func perform(_ action: BrewPackageAction, on package: BrewPackage) {
        switch action {
        case .upgrade: brew.upgrade(package)
        case .pin: brew.pin(package)
        case .uninstall: pendingPackageAction = (package, .uninstall)
        }
    }

    private func operationBar(_ operation: BrewOperation) -> some View {
        let color: Color
        switch operation.state {
        case .running: color = .blue
        case .succeeded: color = .green
        case .failed: color = .red
        case .cancelled: color = .secondary
        }
        return HStack(spacing: 9) {
            if operation.state == .running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: operation.state == .succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(operation.title)
                    .font(.caption.weight(.semibold))
                Text(operation.stateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(operation.state == .running ? "查看输出" : "查看结果") {
                showBrewConsole = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if operation.state == .running {
                Button("取消") { brew.cancelOperation() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            } else {
                Button("关闭") { brew.dismissOperation() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 7)
        .background(Rectangle().fill(color.opacity(0.07)))
    }

    private func messageBanner(text: String, color: Color, icon: String, action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action {
                Button("重试", action: action)
                    .buttonStyle(.link)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.08)))
    }
}

// MARK: - Shared components

struct BrewStatChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.10)))
    }
}

struct BrewPackageIcon: View {
    let package: BrewPackage
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(
                LinearGradient(
                    colors: package.kind == .formula
                        ? [Color.blue.opacity(0.9), Color.cyan.opacity(0.7)]
                        : [Color.purple.opacity(0.9), Color.pink.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: package.kind.icon)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

private struct BrewPackageRow: View {
    let package: BrewPackage
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                BrewPackageIcon(package: package, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(package.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(package.kind.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(package.kind == .formula ? .blue : .purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill((package.kind == .formula ? Color.blue : Color.purple).opacity(0.12)))
                        if package.isDeprecated {
                            Text("已弃用")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(package.description.isEmpty ? package.fullName : package.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if package.dependencyCount > 0 {
                    Label("\(package.dependencyCount)", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if package.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                }
                Text(package.isOutdated ? package.versionChange : package.installedVersion)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(package.isOutdated ? Color.orange : Color.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BrewDependencyGraphCard: View {
    let package: BrewPackage

    var body: some View {
        SectionCard("关系概览") {
            HStack(spacing: 16) {
                VStack(spacing: 6) {
                    BrewPackageIcon(package: package, size: 46)
                    Text(package.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(package.versionChange)
                        .font(.caption2.monospaced())
                        .foregroundStyle(package.isOutdated ? Color.orange : Color.secondary)
                }
                .frame(width: 150)

                VStack(alignment: .leading, spacing: 5) {
                    Text("直接依赖 \(package.dependencyCount)")
                    Text("被依赖 \(package.dependentCount)")
                    Text(package.tap.isEmpty ? "无 tap 信息" : package.tap)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if let installedAt = package.installedAt {
                    Text("安装于 \(installedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct BrewDependencyColumn: View {
    let title: String
    let icon: String
    let color: Color
    let references: [String]
    let service: BrewService
    let onSelect: (BrewPackage) -> Void

    var body: some View {
        SectionCard("\(title)（\(references.count)）") {
            if references.isEmpty {
                Text("无")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(references, id: \.self) { reference in
                        if let package = service.package(reference: reference) {
                            Button {
                                onSelect(package)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: icon)
                                        .font(.caption2)
                                        .foregroundStyle(color)
                                    Text(package.displayName)
                                        .font(.caption.weight(.medium))
                                    Spacer()
                                    Text(package.installedVersion)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        } else {
                            HStack(spacing: 7) {
                                Image(systemName: icon)
                                    .font(.caption2)
                                    .foregroundStyle(color.opacity(0.5))
                                Text(reference)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
