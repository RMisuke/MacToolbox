import Combine
import Foundation

public struct CustomPreset: Codable, Identifiable {
    public var id: String
    public var name: String
    public var values: [String: FieldValue]

    public init(id: String = UUID().uuidString, name: String, values: [String: FieldValue]) {
        self.id = id
        self.name = name
        self.values = values
    }
}

private struct PresetFile: Codable {
    var version: Int
    var presets: [String: [CustomPreset]]
}

@MainActor
public final class PresetStore: ObservableObject {
    @Published public private(set) var presetsByTool: [String: [CustomPreset]] = [:]

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        fileURL = ToolboxPaths.applicationSupport.appendingPathComponent("presets.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        load()
    }

    public func presets(for toolID: String) -> [CustomPreset] {
        presetsByTool[toolID] ?? []
    }

    public func save(_ preset: CustomPreset, for toolID: String) {
        var list = presetsByTool[toolID] ?? []
        if let index = list.firstIndex(where: { $0.id == preset.id }) {
            list[index] = preset
        } else {
            list.append(preset)
        }
        presetsByTool[toolID] = list.sorted { $0.name < $1.name }
        persist()
    }

    public func delete(_ presetID: String, for toolID: String) {
        var list = presetsByTool[toolID] ?? []
        list.removeAll { $0.id == presetID }
        presetsByTool[toolID] = list
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? decoder.decode(PresetFile.self, from: data) else {
            return
        }
        presetsByTool = file.presets
    }

    private func persist() {
        let file = PresetFile(version: 1, presets: presetsByTool)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL)
    }
}
