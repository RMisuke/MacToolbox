import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct CollectionEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let existing: CustomCollection?

    @State private var name: String
    @State private var icon: String
    @State private var selectedIDs: [String]

    private let iconChoices = [
        "square.grid.2x2", "star.fill", "book.closed.fill", "film.fill",
        "folder.fill", "wrench.and.screwdriver.fill", "graduationcap.fill",
        "briefcase.fill", "sparkles", "bolt.fill", "text.book.closed.fill"
    ]

    init(existing: CustomCollection?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "我的集合")
        _icon = State(initialValue: existing?.icon ?? "square.grid.2x2")
        _selectedIDs = State(initialValue: existing?.toolIDs ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing == nil ? "新建工具箱集合" : "编辑工具箱集合")
                        .font(.title2.weight(.semibold))
                    Text("左侧是集合内的工具，可拖动排序；右侧添加/移除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }

            HStack(spacing: 12) {
                TextField("集合名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Picker("图标", selection: $icon) {
                    ForEach(iconChoices, id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).tag(symbol)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
            }

            HStack(alignment: .top, spacing: 16) {
                selectedPane
                Divider()
                availablePane
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Text("\(selectedIDs.count) 个工具")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    _ = model.saveCustomCollection(
                        id: existing?.id,
                        name: name,
                        icon: icon,
                        toolIDs: selectedIDs
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 820, height: 620)
    }

    private var selectedPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("集合内工具")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("拖动排序")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            List {
                ForEach(Array(selectedIDs.enumerated()), id: \.element) { index, id in
                    if let tool = model.tools.first(where: { $0.id == id }) {
                        HStack(spacing: 8) {
                            ToolIconTile(tool: tool, size: 24)
                            Text(tool.manifest.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                move(id: id, delta: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)

                            Button {
                                move(id: id, delta: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(index >= selectedIDs.count - 1)

                            Button {
                                selectedIDs.removeAll { $0 == id }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                        .draggable(id)
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first,
                                  let from = selectedIDs.firstIndex(of: dragged),
                                  let to = selectedIDs.firstIndex(of: id),
                                  from != to else { return false }
                            withAnimation {
                                selectedIDs.move(
                                    fromOffsets: IndexSet(integer: from),
                                    toOffset: to > from ? to + 1 : to
                                )
                            }
                            return true
                        }
                    }
                }
                .onMove { source, destination in
                    selectedIDs.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset)

            if selectedIDs.isEmpty {
                Text("还没有工具；从右侧添加。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var availablePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("可添加工具")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            List {
                ForEach(availableTools) { tool in
                    HStack(spacing: 8) {
                        ToolIconTile(tool: tool, size: 24)
                        Text(tool.manifest.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            selectedIDs.append(tool.id)
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)

            if availableTools.isEmpty {
                Text("所有工具都已在集合内。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 290, alignment: .topLeading)
    }

    private func move(id: String, delta: Int) {
        guard let index = selectedIDs.firstIndex(of: id) else { return }
        let target = index + delta
        guard selectedIDs.indices.contains(target) else { return }
        selectedIDs.swapAt(index, target)
    }

    private var availableTools: [LoadedTool] {
        let selected = Set(selectedIDs)
        return model.tools.filter { !selected.contains($0.id) }
    }
}
