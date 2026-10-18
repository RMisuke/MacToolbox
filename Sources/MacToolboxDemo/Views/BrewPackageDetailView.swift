import AppKit
import SwiftUI

struct BrewPackageDetailView: View {
    let package: BrewPackage
    @ObservedObject var service: BrewService
    let onAction: (BrewPackageAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    infoGrid
                    actionRow
                    if !package.dependencies.isEmpty {
                        referenceSection("直接依赖", icon: "arrow.right.circle", color: .blue, values: package.dependencies)
                    }
                    if !package.dependents.isEmpty {
                        referenceSection("被这些包依赖", icon: "arrow.left.circle", color: .orange, values: package.dependents)
                    }
                    if !package.caveats.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SectionCard("Caveats") {
                            Text(package.caveats)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 680, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("卸载 \(package.name)？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive) { onAction(.uninstall) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会运行 brew uninstall；如果其他包依赖它，Homebrew 会拒绝或提示。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            BrewPackageIcon(package: package, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(package.displayName)
                        .font(.title2.weight(.semibold))
                    Text(package.kind.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(package.kind == .formula ? .blue : .purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((package.kind == .formula ? Color.blue : Color.purple).opacity(0.12)))
                    if package.isPinned {
                        Label("固定", systemImage: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.teal)
                    }
                    if package.isDeprecated {
                        Text("已弃用")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(package.description.isEmpty ? package.fullName : package.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !package.homepage.isEmpty {
                    Text(package.homepage)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }

    private var infoGrid: some View {
        SectionCard("版本与来源") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                GridRow {
                    detailLabel("已安装")
                    Text(package.installedVersion.isEmpty ? "—" : package.installedVersion)
                        .font(.system(.subheadline, design: .monospaced))
                    detailLabel("最新")
                    Text(package.latestVersion.isEmpty ? "—" : package.latestVersion)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(package.isOutdated ? Color.orange : Color.primary)
                }
                GridRow {
                    detailLabel("Tap")
                    Text(package.tap.isEmpty ? "—" : package.tap)
                        .font(.caption.monospaced())
                    detailLabel("License")
                    Text(package.license.isEmpty ? "—" : package.license)
                        .font(.caption)
                }
                GridRow {
                    detailLabel("完整名")
                    Text(package.fullName)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    detailLabel("安装时间")
                    Text(package.installedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if package.isOutdated {
                Button {
                    onAction(.upgrade)
                } label: {
                    Label("升级到 \(package.latestVersion)", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!service.canOperate)
            }
            if package.kind == .formula {
                Button {
                    onAction(.pin)
                } label: {
                    Label(package.isPinned ? "取消固定" : "固定版本", systemImage: package.isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.bordered)
                .disabled(!service.canOperate)
            }
            Button {
                if let url = URL(string: package.homepage) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("主页", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .disabled(package.homepage.isEmpty)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew info \(package.name)", forType: .string)
            } label: {
                Label("复制 brew info", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            Spacer()
            Button(role: .destructive) {
                confirmUninstall = true
            } label: {
                Label("卸载", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!service.canOperate)
        }
    }

    private func referenceSection(_ title: String, icon: String, color: Color, values: [String]) -> some View {
        SectionCard("\(title)（\(values.count)）") {
            FlowLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 9))
                        Text(value)
                            .font(.caption.monospaced())
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(color.opacity(0.09)))
                }
            }
        }
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// 简单的横向换行布局，用于依赖 chip。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
