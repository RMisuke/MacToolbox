import AppKit
import SwiftUI
import Combine
import Foundation
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct QueuedSingleJob: Identifiable {
    let id = UUID()
    let toolID: String
    let toolName: String
    let itemLabel: String?
    let values: [String: FieldValue]
    let createdAt = Date()
}

@MainActor
final class AppModel: ObservableObject {
    enum Destination: String, CaseIterable, Identifiable {
        case home
        case tasks
        case tools
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "主页"
            case .tasks: return "任务"
            case .tools: return "工具管理"
            case .settings: return "设置"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house"
            case .tasks: return "clock.arrow.circlepath"
            case .tools: return "square.stack.3d.up"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var tools: [LoadedTool] = []
    @Published var toolIssues: [ToolIssue] = []
    @Published var destination: Destination = .home
    @Published var homePath = NavigationPath()
    @Published var toolValues: [String: [String: FieldValue]] = [:]
    @Published var quickRunTool: LoadedTool?
    @Published var settingsTool: LoadedTool?
    @Published var showConsole = false
    @Published var consoleChildID: String?
    @Published var showSetup = false
    @Published private(set) var queuedJobs: [QueuedSingleJob] = []
    @Published var validationMessage: String?
    @Published var jobToolName: String?
    @Published var batchTool: LoadedTool?
    @Published var selectedCollectionID: String = "all"

    let store: JobStore
    let coordinator: JobCoordinator
    let prefs: PreferencesStore
    let lexiconStore: LexiconStore
    let presetStore: PresetStore
    let modelCatalog = ModelCatalog()
    let resourceMonitor = ResourceMonitor()
    let doctor = DoctorController()
    let setup = SetupController()
    let brewService = BrewService()
    let agentJobs = AgentJobMonitor()

    var job: JobRunner { coordinator.runner }

    private var autoRunSubscription: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var autoQuit = false
    private var lastGroupState: GroupStatus?
    private var notificationsRequested = false
    private var queueDrainScheduled = false

    init() {
        let prefs = PreferencesStore()
        let store = JobStore()
        let coordinator = JobCoordinator(store: store)
        self.prefs = prefs
        self.store = store
        self.coordinator = coordinator
        self.selectedCollectionID = prefs.preferences.selectedCollectionID
        if let raw = ProcessInfo.processInfo.environment["MCT_START_DESTINATION"],
           let target = Destination(rawValue: raw) {
            destination = target
        }

        let orphanReport = OrphanCleaner.cleanup()
        if !orphanReport.isEmpty {
            NSLog("OrphanCleaner: killed %@", orphanReport.killedPIDs.map(String.init).joined(separator: ","))
        }

        let scan = ToolRegistry.scan()
        let discovered = scan.tools
        tools = discovered
        toolIssues = scan.issues
        let migratedSecrets = SecretMigrator.migrate(tools: discovered, store: store)
        if migratedSecrets > 0 {
            NSLog("SecretMigrator: moved %d legacy secret(s) to Keychain", migratedSecrets)
        }
        self.lexiconStore = LexiconStore(toolDirectories: discovered.map(\.directory))
        self.presetStore = PresetStore()
        agentJobs.start()
        for tool in tools {
            if let stored = prefs.storedValues(for: tool.id), !stored.isEmpty {
                var merged = makeDefaultValues(for: tool)
                for (key, value) in stored where merged[key] != nil {
                    merged[key] = value
                }
                for field in tool.manifest.inputs where field.type == "secret" {
                    let secret = merged[field.key]?.stringValue ?? ""
                    if !secret.isEmpty {
                        if SecretStore.value(toolID: tool.id, key: field.key) == nil {
                            SecretStore.set(secret, toolID: tool.id, key: field.key)
                        }
                        merged[field.key] = .string("")
                    }
                }
                fillPromptIfNeeded(&merged, tool: tool)
                toolValues[tool.id] = merged
            } else {
                ensureValues(for: tool)
            }
        }
        if let first = tools.first(where: { !$0.isNative && $0.manifest.doctor != nil })
            ?? tools.first(where: { !$0.isNative }) {
            doctor.check(tool: first, values: values(for: first))
        }
        if let startTool = ProcessInfo.processInfo.environment["MCT_START_TOOL_ID"],
           tools.contains(where: { $0.id == startTool }) {
            homePath = NavigationPath()
            homePath.append(startTool)
        }

        coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        prefs.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        lexiconStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        presetStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        modelCatalog.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        resourceMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        agentJobs.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.agentJobs.stop()
                self?.shutdownForTermination()
            }
            .store(in: &cancellables)
        coordinator.$group
            .sink { [weak self] group in
                guard let self else { return }
                self.handleGroupNotification(group)
                if let group, group.state.isTerminal {
                    self.scheduleQueueDrain()
                }
            }
            .store(in: &cancellables)
        job.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if let base = ProcessInfo.processInfo.environment["MCT_TEST_MODELS"], !base.isEmpty {
            modelCatalog.fetch(
                baseURL: base,
                apiKey: ProcessInfo.processInfo.environment["MCT_TEST_MODELS_KEY"] ?? ""
            )
            modelCatalog.$models
                .sink { NSLog("MCT models: %@", $0.joined(separator: ",")) }
                .store(in: &cancellables)
            modelCatalog.$errorMessage
                .compactMap { $0 }
                .sink { NSLog("MCT models error: %@", $0) }
                .store(in: &cancellables)
        }

        if let path = ProcessInfo.processInfo.environment["MCT_TEST_LEXICON_IMPORT"], !path.isEmpty {
            do {
                let result = try LexiconImportParser.parse(url: URL(fileURLWithPath: path))
                NSLog(
                    "MCT lexicon parse: hot=%d rules=%d dup=%d errors=%d",
                    result.hotwords.count,
                    result.rules.count,
                    result.duplicateHotwords + result.duplicateRules,
                    result.errors.count
                )
                let first = try lexiconStore.importLexicon(
                    result,
                    into: nil,
                    name: "MCT Test",
                    toolID: "media.subtitle",
                    overwriteRules: false
                )
                NSLog(
                    "MCT lexicon import1: id=%@ v=%d added=%d/%d",
                    first.profile.id,
                    first.profile.version ?? 0,
                    first.summary.addedHotwords,
                    first.summary.addedRules
                )
                let versions = lexiconStore.history(for: first.profile.id)
                NSLog("MCT lexicon versions: %@", versions.map { "v\($0.number)" }.joined(separator: ","))
                if let oldest = versions.last {
                    let rolled = try lexiconStore.rollback(id: first.profile.id, to: oldest.number)
                    NSLog("MCT lexicon rollback: v%d", rolled.version ?? 0)
                }
                let second = try lexiconStore.importLexicon(
                    result,
                    into: first.profile.id,
                    name: "MCT Test",
                    toolID: "media.subtitle",
                    overwriteRules: true
                )
                NSLog(
                    "MCT lexicon import2: v=%d added=%d/%d skipped=%d/%d",
                    second.profile.version ?? 0,
                    second.summary.addedHotwords,
                    second.summary.addedRules,
                    second.summary.skippedHotwords,
                    second.summary.skippedRules
                )

                if let secondPath = ProcessInfo.processInfo.environment["MCT_TEST_LEXICON_SECOND"],
                   !secondPath.isEmpty {
                    let overwrite = ProcessInfo.processInfo.environment["MCT_TEST_LEXICON_OVERWRITE"] == "1"
                    let result2 = try LexiconImportParser.parse(url: URL(fileURLWithPath: secondPath))
                    let merged = try lexiconStore.importLexicon(
                        result2,
                        into: first.profile.id,
                        name: "MCT Test",
                        toolID: "media.subtitle",
                        overwriteRules: overwrite
                    )
                    NSLog(
                        "MCT lexicon conflict: v=%d added=%d/%d conflicts=%d overwrite=%@",
                        merged.profile.version ?? 0,
                        merged.summary.addedHotwords,
                        merged.summary.addedRules,
                        merged.summary.conflicts.count,
                        overwrite ? "yes" : "no"
                    )
                }
            } catch {
                NSLog("MCT lexicon error: %@", error.localizedDescription)
            }
        }

        if !notificationsRequested {
            notificationsRequested = true
            NotificationController.shared.requestAuthorization()
        }

        scheduleAutoRunIfRequested()
    }

    private func handleGroupNotification(_ group: JobGroupRecord?) {
        guard let group else {
            lastGroupState = nil
            return
        }
        let previous = lastGroupState
        lastGroupState = group.state
        guard group.state.isTerminal,
              previous != group.state,
              previous?.isTerminal != true,
              prefs.notificationsEnabled else { return }

        let counts = store.counts(of: group)
        switch group.state {
        case .succeeded:
            NotificationController.shared.post(
                title: "MacToolbox 任务完成",
                body: "\(group.title)：\(counts.done)/\(counts.total) 完成"
            )
        case .failed:
            NotificationController.shared.post(
                title: "MacToolbox 任务失败",
                body: "\(group.title)：\(counts.failed) 项失败"
            )
        case .cancelled:
            NotificationController.shared.post(
                title: "MacToolbox 任务已停止",
                body: group.title
            )
        default:
            break
        }
    }

    var runnableTools: [LoadedTool] { tools.filter(\.isRunnable) }

    var primaryTool: LoadedTool? { runnableTools.first ?? tools.first }

    var userToolsDirectory: URL {
        ToolboxPaths.applicationSupport.appendingPathComponent("Tools", isDirectory: true)
    }

    var isEnvironmentReady: Bool {
        !doctor.checks.isEmpty && doctor.checks.allSatisfy { $0.status == "ok" }
    }

    var environmentIssueCount: Int {
        doctor.checks.filter { $0.status != "ok" }.count
    }

    var collections: [ToolCollection] {
        var result: [ToolCollection] = [
            ToolCollection(
                id: "all",
                name: "全部工具",
                icon: "square.grid.2x2",
                toolIDs: tools.map(\.id)
            )
        ]

        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for tool in tools {
            let category = tool.manifest.category ?? "其他"
            if grouped[category] == nil {
                order.append(category)
            }
            grouped[category, default: []].append(tool.id)
        }
        for category in order {
            result.append(
                ToolCollection(
                    id: "category:\(category)",
                    name: category,
                    icon: "square.stack.3d.up",
                    toolIDs: grouped[category] ?? []
                )
            )
        }
        for custom in prefs.allCustomCollections {
            result.append(
                ToolCollection(
                    id: custom.id,
                    name: custom.name,
                    icon: custom.icon,
                    toolIDs: custom.toolIDs
                )
            )
        }
        return result
    }

    var customCollections: [CustomCollection] {
        prefs.allCustomCollections
    }

    var selectedCollection: ToolCollection {
        collections.first(where: { $0.id == selectedCollectionID }) ?? collections[0]
    }

    var recentTools: [LoadedTool] {
        tools
            .filter { prefs.lastUsed($0.id) != nil }
            .sorted { (prefs.lastUsed($0.id) ?? .distantPast) > (prefs.lastUsed($1.id) ?? .distantPast) }
    }

    var favoriteTools: [LoadedTool] {
        tools.filter { prefs.isFavorite($0.id) }
    }

    var pinnedTools: [LoadedTool] {
        tools.filter { prefs.isPinned($0.id) }
    }

    func selectCollection(_ id: String) {
        selectedCollectionID = id
        prefs.selectCollection(id)
        homePath = NavigationPath()
    }

    func tools(in collection: ToolCollection) -> [LoadedTool] {
        let byID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        return collection.toolIDs.compactMap { byID[$0] }
    }

    /// 自定义集合尊重用户拖拽顺序；其他集合仍按置顶/收藏/名称排序。
    func displayTools(_ tools: [LoadedTool], in collection: ToolCollection) -> [LoadedTool] {
        if collection.id.hasPrefix("custom-") {
            return tools
        }
        return sortedTools(tools)
    }

    @discardableResult
    func saveCustomCollection(
        id: String?,
        name: String,
        icon: String,
        toolIDs: [String]
    ) -> CustomCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var seen = Set<String>()
        let ordered = toolIDs.filter { seen.insert($0).inserted }
        let collection = CustomCollection(
            id: id ?? "custom-" + String(UUID().uuidString.prefix(8)).lowercased(),
            name: trimmed,
            icon: icon,
            toolIDs: ordered
        )
        return prefs.saveCustomCollection(collection)
    }

    func deleteCustomCollection(_ id: String) {
        prefs.deleteCustomCollection(id)
        if selectedCollectionID == id {
            selectedCollectionID = "all"
        }
        if !collections.contains(where: { $0.id == selectedCollectionID }) {
            selectedCollectionID = "all"
        }
        homePath = NavigationPath()
    }

    func moveCustomCollection(from source: IndexSet, to destination: Int) {
        prefs.moveCustomCollection(from: source, to: destination)
    }

    func sortedTools(_ tools: [LoadedTool]) -> [LoadedTool] {
        tools.sorted { lhs, rhs in
            let lp = prefs.isPinned(lhs.id)
            let rp = prefs.isPinned(rhs.id)
            if lp != rp { return lp }
            let lf = prefs.isFavorite(lhs.id)
            let rf = prefs.isFavorite(rhs.id)
            if lf != rf { return lf }
            return lhs.manifest.name < rhs.manifest.name
        }
    }

    func toggleFavorite(_ tool: LoadedTool) {
        prefs.toggleFavorite(tool.id)
    }

    func togglePinned(_ tool: LoadedTool) {
        prefs.togglePinned(tool.id)
    }

    // MARK: - Values

    func values(for tool: LoadedTool) -> [String: FieldValue] {
        toolValues[tool.id] ?? [:]
    }

    func ensureValues(for tool: LoadedTool) {
        guard toolValues[tool.id] == nil else { return }
        var values = makeDefaultValues(for: tool)
        if let presetID = values["preset"]?.stringValue {
            applyPreset(presetID, to: &values, tool: tool, updateSelection: true)
        }
        toolValues[tool.id] = values
    }

    private func persistableValues(_ values: [String: FieldValue], tool: LoadedTool) -> [String: FieldValue] {
        var result = values
        for field in tool.manifest.inputs where field.type == "secret" {
            result.removeValue(forKey: field.key)
        }
        return result
    }

    func makeDefaultValues(for tool: LoadedTool) -> [String: FieldValue] {
        var result: [String: FieldValue] = [:]
        for field in tool.manifest.inputs {
            result[field.key] = field.defaultValue ?? .string("")
        }
        fillPromptIfNeeded(&result, tool: tool)
        return result
    }

    private func shutdownForTermination() {
        if coordinator.isActive {
            coordinator.forceCancel()
        }
        if job.state.isActive {
            job.forceCancel()
        }
    }

    private func fillPromptIfNeeded(_ values: inout [String: FieldValue], tool: LoadedTool) {
        guard values["llmPrompt"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
            return
        }
        let presetID = values["llmPromptPreset"]?.stringValue ?? "general"
        guard presetID != "custom",
              let preset = tool.manifest.promptPresets?.first(where: { $0.id == presetID }) else {
            return
        }
        values["llmPrompt"] = .string(preset.prompt)
    }

    func applyPreset(
        _ id: String,
        to values: inout [String: FieldValue],
        tool: LoadedTool,
        updateSelection: Bool
    ) {
        guard id != "custom" else {
            if updateSelection { values["preset"] = .string("custom") }
            return
        }
        guard let preset = allPresets(for: tool).first(where: { $0.id == id }) else { return }
        for (key, value) in preset.values {
            values[key] = value
        }
        if updateSelection {
            values["preset"] = .string(id)
        }
    }

    func setValue(_ value: FieldValue, for key: String, tool: LoadedTool) {
        ensureValues(for: tool)
        var values = values(for: tool)

        if key == "preset" {
            applyPreset(value.stringValue, to: &values, tool: tool, updateSelection: true)
            toolValues[tool.id] = values
            prefs.saveValues(persistableValues(values, tool: tool), for: tool.id)
            return
        }

        values[key] = value

        if let field = tool.manifest.inputs.first(where: { $0.key == key }),
           field.type == "secret" {
            if value.stringValue.isEmpty {
                SecretStore.delete(toolID: tool.id, key: key)
            } else if !SecretStore.set(value.stringValue, toolID: tool.id, key: key) {
                NSLog("SecretStore: failed to save %@.%@", tool.id, key)
            }
        }

        if key == "llmPromptPreset" {
            if value.stringValue != "custom",
               let preset = tool.manifest.promptPresets?.first(where: { $0.id == value.stringValue }) {
                values["llmPrompt"] = .string(preset.prompt)
            }
        } else if key == "llmPrompt" {
            values["llmPromptPreset"] = .string("custom")
        }

        // 只有真正改动了预设覆盖的字段，才切换为「自定义」。
        if let presetID = values["preset"]?.stringValue,
           presetID != "custom",
           let preset = tool.manifest.allPresets.first(where: { $0.id == presetID }) {
            for (presetKey, presetValue) in preset.values where values[presetKey] != presetValue {
                values["preset"] = .string("custom")
                break
            }
        }
        toolValues[tool.id] = values
        prefs.saveValues(persistableValues(values, tool: tool), for: tool.id)
    }

    func resetDefaults(for tool: LoadedTool) {
        var values = makeDefaultValues(for: tool)
        if let presetID = values["preset"]?.stringValue {
            applyPreset(presetID, to: &values, tool: tool, updateSelection: true)
        }
        toolValues[tool.id] = values
        prefs.saveValues(persistableValues(values, tool: tool), for: tool.id)
        validationMessage = nil
    }

    /// 工具目录发生变化（新建/手工放入/删除）后热刷新，不必重启 App。
    func reloadTools() {
        let scan = ToolRegistry.scan()
        tools = scan.tools
        toolIssues = scan.issues
        lexiconStore.updateToolDirectories(scan.tools.map(\.directory))
        for tool in tools {
            ensureValues(for: tool)
        }
        if !collections.contains(where: { $0.id == selectedCollectionID }) {
            selectedCollectionID = "all"
        }
        if doctor.checks.isEmpty,
           let first = tools.first(where: { !$0.isNative && $0.manifest.doctor != nil })
               ?? tools.first(where: { !$0.isNative }) {
            doctor.check(tool: first, values: values(for: first))
        }
    }

    // MARK: - Fields

    func isVisible(_ field: InputField, for tool: LoadedTool) -> Bool {
        guard let condition = field.visibleWhen else { return true }
        return values(for: tool)[condition.field]?.stringValue == condition.equals.stringValue
    }

    func quickFields(for tool: LoadedTool) -> [InputField] {
        let keys = tool.manifest.quick?.allInputs ?? []
        let source = tool.manifest.inputs
        if !keys.isEmpty {
            return keys.compactMap { key in
                source.first(where: { $0.key == key })
            }.filter { isVisible($0, for: tool) }
        }
        return source.filter {
            ($0.isRequired || !$0.isAdvanced) && isVisible($0, for: tool)
        }
    }

    func fullFields(for tool: LoadedTool) -> [InputField] {
        tool.manifest.inputs.filter { isVisible($0, for: tool) }
    }

    func fields(for tool: LoadedTool, keys: [String]?) -> [InputField] {
        guard let keys else { return fullFields(for: tool) }
        return keys.compactMap { key in
            tool.manifest.inputs.first(where: { $0.key == key })
        }.filter { isVisible($0, for: tool) }
    }

    func groups(for fields: [InputField]) -> [FormGroup] {
        var order: [String] = []
        var grouped: [String: [InputField]] = [:]
        for field in fields {
            if grouped[field.groupName] == nil {
                order.append(field.groupName)
            }
            grouped[field.groupName, default: []].append(field)
        }
        return order.map { FormGroup(id: $0, title: $0, fields: grouped[$0] ?? []) }
    }

    // MARK: - Prompt / Preset / Lexicon

    func allPresets(for tool: LoadedTool) -> [Preset] {
        tool.manifest.allPresets + presetStore.presets(for: tool.id).map {
            Preset(id: $0.id, name: $0.name, values: $0.values)
        }
    }

    func customPresets(for tool: LoadedTool) -> [CustomPreset] {
        presetStore.presets(for: tool.id)
    }

    @discardableResult
    func saveCustomPreset(
        tool: LoadedTool,
        id: String?,
        name: String,
        values: [String: FieldValue]
    ) -> CustomPreset {
        let preset = CustomPreset(
            id: id ?? "custom-" + UUID().uuidString.prefix(6),
            name: name,
            values: values
        )
        presetStore.save(preset, for: tool.id)
        return preset
    }

    func deleteCustomPreset(_ presetID: String, tool: LoadedTool) {
        presetStore.delete(presetID, for: tool.id)
        if values(for: tool)["preset"]?.stringValue == presetID {
            var updated = values(for: tool)
            updated["preset"] = .string("custom")
            toolValues[tool.id] = updated
            prefs.saveValues(persistableValues(updated, tool: tool), for: tool.id)
        }
    }

    func promptPresets(for tool: LoadedTool) -> [PromptPreset] {
        tool.manifest.promptPresets ?? []
    }

    func lexiconProfiles(for tool: LoadedTool) -> [LexiconProfile] {
        lexiconStore.profiles(for: tool.id)
    }

    func matchedLexicon(for tool: LoadedTool, pathHint: String? = nil) -> LexiconMatch? {
        let path = pathHint ?? values(for: tool)["video"]?.stringValue ?? ""
        guard !path.isEmpty else { return nil }
        return lexiconStore.match(path: path, toolID: tool.id)
    }

    func selectedLexicon(for tool: LoadedTool, pathHint: String? = nil) -> LexiconProfile? {
        let selection = values(for: tool)["termProfile"]?.stringValue ?? "auto"
        switch selection {
        case "none":
            return nil
        case "auto":
            return matchedLexicon(for: tool, pathHint: pathHint)?.profile
        default:
            if let profile = lexiconStore.profile(id: selection) {
                return profile
            }
            return matchedLexicon(for: tool, pathHint: pathHint)?.profile
        }
    }

    func prepareJobValues(
        tool: LoadedTool,
        values: [String: FieldValue],
        pathHint: String? = nil
    ) -> [String: FieldValue] {
        var effective = values
        guard let profile = selectedLexicon(for: tool, pathHint: pathHint) else {
            return effective
        }

        effective["_lexiconProfileID"] = .string(profile.id)
        effective["_lexiconProfileName"] = .string(profile.name)
        effective["_lexiconHotwords"] = .string(profile.allHotwords.joined(separator: "\n"))
        let rules = profile.allRules.map { rule -> [String: String] in
            [
                "from": rule.from,
                "to": rule.to,
                "source": rule.source ?? "profile"
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rules),
           let json = String(data: data, encoding: .utf8) {
            effective["_lexiconRules"] = .string(json)
        }
        return effective
    }

    func fetchModels(baseURL: String, apiKey: String) {
        modelCatalog.fetch(baseURL: baseURL, apiKey: apiKey)
    }

    // MARK: - Actions

    func recheckEnvironment(for tool: LoadedTool? = nil) {
        guard let tool = tool ?? primaryTool, !tool.isNative else { return }
        doctor.check(tool: tool, values: values(for: tool))
    }

    func run(tool: LoadedTool) {
        guard tool.isRunnable else { return }
        let values = values(for: tool)
        validationMessage = validate(tool: tool, values: values)
        guard validationMessage == nil else {
            quickRunTool = tool
            return
        }
        let effective = prepareJobValues(
            tool: tool,
            values: values,
            pathHint: tool.primaryPath(in: values)
        )

        if coordinator.isActive || job.state.isActive {
            enqueueSingle(tool: tool, values: effective)
            quickRunTool = nil
            return
        }

        jobToolName = tool.manifest.name
        prefs.recordUse(tool.id)
        coordinator.startSingle(tool: tool, values: effective)
        showConsole = true
        quickRunTool = nil
    }

    func enqueueSingle(tool: LoadedTool, values: [String: FieldValue]) {
        let item = tool.primaryPath(in: values).map { URL(fileURLWithPath: $0).lastPathComponent }
        queuedJobs.append(
            QueuedSingleJob(
                toolID: tool.id,
                toolName: tool.manifest.name,
                itemLabel: item,
                values: values
            )
        )
        if queuedJobs.count > 20 {
            queuedJobs.removeFirst(queuedJobs.count - 20)
        }
        queueNotice = "已加入队列：\(item ?? tool.manifest.name)"
    }

    @Published var queueNotice: String?

    func removeQueuedJob(_ id: UUID) {
        queuedJobs.removeAll { $0.id == id }
    }

    func clearQueuedJobs() {
        queuedJobs.removeAll()
    }

    private func scheduleQueueDrain() {
        guard !queuedJobs.isEmpty, !queueDrainScheduled else { return }
        queueDrainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.queueDrainScheduled = false
            self.startNextQueuedJob()
        }
    }

    private func startNextQueuedJob() {
        guard !coordinator.isActive, !job.state.isActive else { return }
        guard let next = queuedJobs.first else { return }
        queuedJobs.removeFirst()
        guard let tool = tools.first(where: { $0.id == next.toolID }) else {
            startNextQueuedJob()
            return
        }
        jobToolName = next.toolName
        prefs.recordUse(tool.id)
        coordinator.startSingle(tool: tool, values: next.values)
    }

    func openBatchRun(_ tool: LoadedTool) {
        guard tool.manifest.batch != nil else { return }
        ensureValues(for: tool)
        validationMessage = nil
        batchTool = tool
    }

    func runBatch(
        tool: LoadedTool,
        files: [URL],
        outputDirectory: String,
        skipExisting: Bool,
        stopOnError: Bool
    ) {
        guard !coordinator.isActive, !job.state.isActive, !files.isEmpty else { return }
        let values = values(for: tool)
        validationMessage = validate(tool: tool, values: values, ignoreBatchInput: true)
        guard validationMessage == nil else { return }

        jobToolName = "\(tool.manifest.name) · 批量"
        prefs.recordUse(tool.id)
        let effective = prepareJobValues(
            tool: tool,
            values: values,
            pathHint: files.first?.path
        )
        coordinator.startBatch(
            tool: tool,
            values: effective,
            files: files,
            outputDirectory: outputDirectory,
            skipExisting: skipExisting,
            stopOnError: stopOnError
        )
        showConsole = true
        batchTool = nil
    }

    func resumeGroup(_ group: JobGroupRecord) {
        guard !coordinator.isActive, !job.state.isActive else { return }
        guard let tool = tools.first(where: { $0.id == group.toolID }) else {
            validationMessage = "找不到工具：\(group.toolID)"
            return
        }
        ensureValues(for: tool)
        jobToolName = group.title
        prefs.recordUse(tool.id)

        let batchInput = tool.manifest.batch?.input ?? tool.primaryPathKey ?? "video"
        let pathHint: String?
        if group.isBatch {
            pathHint = store.children(of: group).first?.values[batchInput]?.stringValue
        } else {
            pathHint = tool.primaryPath(in: values(for: tool))
        }
        let effective = prepareJobValues(
            tool: tool,
            values: values(for: tool),
            pathHint: pathHint
        )
        coordinator.resume(group: group, tool: tool, overrideValues: effective)
        showConsole = true
        destination = .tasks
    }

    func goHome() {
        destination = .home
        homePath = NavigationPath()
    }

    func openConsole(childID: String? = nil) {
        consoleChildID = childID
        showConsole = true
    }

    func openQuickRun(_ tool: LoadedTool) {
        guard tool.isRunnable else { return }
        ensureValues(for: tool)
        validationMessage = nil
        quickRunTool = tool
    }

    func openSettings(_ tool: LoadedTool) {
        guard !tool.isNative else { return }
        ensureValues(for: tool)
        settingsTool = tool
        recheckEnvironment(for: tool)
    }

    func validate(
        tool: LoadedTool,
        values: [String: FieldValue],
        ignoreBatchInput: Bool = false
    ) -> String? {
        var missing: [String] = []
        let batchInput = tool.manifest.batch?.input
        for field in tool.manifest.inputs where isVisible(field, for: tool) {
            if ignoreBatchInput && field.key == batchInput { continue }
            if field.isRequired && (values[field.key]?.isEmpty ?? true) {
                missing.append(field.label)
            }
        }
        if !missing.isEmpty {
            return "请先填写：" + missing.joined(separator: "、")
        }

        if values["backend"]?.stringValue == "cloud" {
            if values["cloudBaseURL"]?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                return "云端模式需要填写 Base URL"
            }
            if values["cloudModel"]?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                return "云端模式需要填写转写模型"
            }
        }
        if values["reviewMode"]?.stringValue == "llm" {
            if values["llmBaseURL"]?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                return "LLM 校对需要填写 Base URL"
            }
            if values["llmModel"]?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                return "LLM 校对需要填写模型名"
            }
        }
        if values["backend"]?.stringValue == "local" {
            let model = values["modelPath"]?.stringValue ?? ""
            let expanded = (model as NSString).expandingTildeInPath
            if !model.isEmpty && !FileManager.default.fileExists(atPath: expanded) {
                return "无法访问本地模型：\(model)\n若模型在外置盘，请先在系统弹窗中授权；或在「环境修复」中下载。"
            }
        }
        return nil
    }

    // MARK: - Headless self-test

    /// 供开发自测：设置 MCT_AUTORUN_VIDEO 后启动 App，自动填表并运行一次。
    private func scheduleAutoRunIfRequested() {
        let env = ProcessInfo.processInfo.environment
        let video = env["MCT_AUTORUN_VIDEO"] ?? ""
        let batchDir = env["MCT_AUTORUN_BATCH_DIR"] ?? ""
        let resumeLast = env["MCT_AUTORUN_RESUME_LAST"] == "1"
        guard !video.isEmpty || !batchDir.isEmpty || resumeLast else { return }
        guard let tool = primaryTool else { return }

        autoQuit = env["MCT_AUTORUN_QUIT"] == "1"
        ensureValues(for: tool)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }

            if resumeLast, let group = self.store.resumableGroups.first {
                self.resumeGroup(group)
            } else {
                if !video.isEmpty {
                    self.setValue(.string(video), for: "video", tool: tool)
                }
                if let output = env["MCT_AUTORUN_OUTPUT"], !output.isEmpty {
                    self.setValue(.string(output), for: "outputDir", tool: tool)
                }
                if let review = env["MCT_AUTORUN_REVIEW"], !review.isEmpty {
                    self.setValue(.string(review), for: "reviewMode", tool: tool)
                }
                if let cloudBase = env["MCT_AUTORUN_CLOUD_BASE"], !cloudBase.isEmpty {
                    self.setValue(.string("cloud"), for: "backend", tool: tool)
                    self.setValue(.string(cloudBase), for: "cloudBaseURL", tool: tool)
                    self.setValue(.string(env["MCT_AUTORUN_CLOUD_MODEL"] ?? "whisper-1"), for: "cloudModel", tool: tool)
                    if let key = env["MCT_AUTORUN_CLOUD_KEY"], !key.isEmpty {
                        self.setValue(.string(key), for: "cloudAPIKey", tool: tool)
                    }
                }
                if let llmBase = env["MCT_AUTORUN_LLM_BASE"], !llmBase.isEmpty {
                    self.setValue(.string("llm"), for: "reviewMode", tool: tool)
                    self.setValue(.string(llmBase), for: "llmBaseURL", tool: tool)
                    self.setValue(.string(env["MCT_AUTORUN_LLM_MODEL"] ?? "mock"), for: "llmModel", tool: tool)
                    if let key = env["MCT_AUTORUN_LLM_KEY"], !key.isEmpty {
                        self.setValue(.string(key), for: "llmAPIKey", tool: tool)
                    }
                    self.setValue(.bool(true), for: "llmFallback", tool: tool)
                }

                self.validationMessage = nil
                if !batchDir.isEmpty {
                    let files = self.scanBatchDirectory(URL(fileURLWithPath: batchDir), tool: tool)
                    self.runBatch(
                        tool: tool,
                        files: files,
                        outputDirectory: env["MCT_AUTORUN_OUTPUT"] ?? "",
                        skipExisting: true,
                        stopOnError: false
                    )
                } else {
                    self.run(tool: tool)
                }
            }

                if let queueVideo = env["MCT_AUTORUN_QUEUE_VIDEO"], !queueVideo.isEmpty {
                    self.setValue(.string(queueVideo), for: "video", tool: tool)
                    self.run(tool: tool)
                }

            NSLog("MCT autorun started, autoQuit=%@", self.autoQuit ? "true" : "false")
            if let value = env["MCT_AUTORUN_FORCE_STOP_AFTER"],
               let seconds = Double(value), seconds >= 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.coordinator.forceCancel()
                }
            }
            self.autoRunSubscription = self.coordinator.$group.sink { [weak self] group in
                guard let self, let group else { return }
                NSLog("MCT autorun group=%@", group.state.rawValue)
                guard self.autoQuit, group.state.isTerminal else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApplication.shared.terminate(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        exit(0)
                    }
                }
            }
        }
    }

    private func scanBatchDirectory(_ folder: URL, tool: LoadedTool) -> [URL] {
        let accept = Set(
            (tool.manifest.batch?.allAccept ?? ["mp4", "mov", "mkv", "m4v"])
                .map { $0.lowercased() }
        )
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { accept.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

struct FormGroup: Identifiable {
    let id: String
    let title: String
    let fields: [InputField]
}
