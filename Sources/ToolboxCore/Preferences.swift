import Combine
import Foundation

public struct ToolPreferences: Codable {
    public var favorites: Set<String> = []
    public var pinned: Set<String> = []
    public var lastUsed: [String: Date] = [:]
    public var runCount: [String: Int] = [:]
    public var selectedCollectionID: String = "all"
    public var toolValues: [String: [String: FieldValue]]?
    public var customCollections: [CustomCollection]?
    public var notificationsEnabled: Bool?

    public init() {}
}

public struct CustomCollection: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var icon: String
    public var toolIDs: [String]

    public init(id: String = "custom-" + UUID().uuidString.prefix(8).lowercased(),
                name: String,
                icon: String,
                toolIDs: [String]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.toolIDs = toolIDs
    }
}

@MainActor
public final class PreferencesStore: ObservableObject {
    @Published public private(set) var preferences = ToolPreferences()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        fileURL = ToolboxPaths.applicationSupport.appendingPathComponent("preferences.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    public func isFavorite(_ toolID: String) -> Bool {
        preferences.favorites.contains(toolID)
    }

    public func isPinned(_ toolID: String) -> Bool {
        preferences.pinned.contains(toolID)
    }

    public func lastUsed(_ toolID: String) -> Date? {
        preferences.lastUsed[toolID]
    }

    public func runCount(_ toolID: String) -> Int {
        preferences.runCount[toolID] ?? 0
    }

    public func toggleFavorite(_ toolID: String) {
        if preferences.favorites.contains(toolID) {
            preferences.favorites.remove(toolID)
        } else {
            preferences.favorites.insert(toolID)
        }
        save()
    }

    public func togglePinned(_ toolID: String) {
        if preferences.pinned.contains(toolID) {
            preferences.pinned.remove(toolID)
        } else {
            preferences.pinned.insert(toolID)
        }
        save()
    }

    public func recordUse(_ toolID: String) {
        preferences.lastUsed[toolID] = Date()
        preferences.runCount[toolID, default: 0] += 1
        save()
    }

    public func selectCollection(_ id: String) {
        preferences.selectedCollectionID = id
        save()
    }

    public var allCustomCollections: [CustomCollection] {
        preferences.customCollections ?? []
    }

    public var notificationsEnabled: Bool {
        preferences.notificationsEnabled ?? true
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        preferences.notificationsEnabled = enabled
        save()
    }

    @discardableResult
    public func saveCustomCollection(_ collection: CustomCollection) -> CustomCollection {
        var collections = allCustomCollections
        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[index] = collection
        } else {
            collections.append(collection)
        }
        preferences.customCollections = collections
        save()
        return collection
    }

    public func deleteCustomCollection(_ id: String) {
        var collections = allCustomCollections
        collections.removeAll { $0.id == id }
        preferences.customCollections = collections
        if preferences.selectedCollectionID == id {
            preferences.selectedCollectionID = "all"
        }
        save()
    }

    public func moveCustomCollection(from source: IndexSet, to destination: Int) {
        var collections = allCustomCollections
        let indices = source.sorted()
        let moving = indices.compactMap { collections.indices.contains($0) ? collections[$0] : nil }
        for index in indices.reversed() where collections.indices.contains(index) {
            collections.remove(at: index)
        }
        let removedBefore = indices.filter { $0 < destination }.count
        let target = min(max(destination - removedBefore, 0), collections.count)
        collections.insert(contentsOf: moving, at: target)
        preferences.customCollections = collections
        save()
    }

    public func storedValues(for toolID: String) -> [String: FieldValue]? {
        preferences.toolValues?[toolID]
    }

    public func saveValues(_ values: [String: FieldValue], for toolID: String) {
        var all = preferences.toolValues ?? [:]
        all[toolID] = values
        preferences.toolValues = all
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(ToolPreferences.self, from: data) else {
            return
        }
        preferences = decoded
    }

    private func save() {
        guard let data = try? encoder.encode(preferences) else { return }
        try? data.write(to: fileURL)
    }
}

public struct ToolCollection: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let icon: String
    public let toolIDs: [String]

    public init(id: String, name: String, icon: String, toolIDs: [String]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.toolIDs = toolIDs
    }
}
