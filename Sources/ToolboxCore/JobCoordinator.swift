import Combine
import Foundation

@MainActor
public final class JobCoordinator: ObservableObject {
    public private(set) var runner: JobRunner
    private let store: JobStore

    @Published public private(set) var group: JobGroupRecord?
    @Published public private(set) var children: [JobRecord] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var currentChildID: String?

    private var tool: LoadedTool?
    private var pendingIDs: [String] = []
    private var resources: [String] = []
    private var runToken = UUID()
    private var isCancelling = false
    private var terminalHandled = false
    private var runtimeSecrets: [String: String] = [:]

    private var usingPool = false
    private var poolPending: [String] = []
    private var poolActive = Set<String>()
    private var poolRunners: [String: JobRunner] = [:]
    private var poolBindings: [String: [AnyCancellable]] = [:]
    private var poolResources: [String: [String]] = [:]
    private var poolTerminal = Set<String>()

    private var stateCancellable: AnyCancellable?
    private var progressCancellable: AnyCancellable?

    public init(store: JobStore) {
        self.store = store
        self.runner = JobRunner()
        bindRunner()
    }

    // MARK: - Public state

    public var progress: Double {
        guard !children.isEmpty else { return 0 }
        let total = children.reduce(0.0) { partial, child in
            if child.state == .succeeded || child.state == .skipped { return partial + 1 }
            return partial + child.progress
        }
        return min(max(total / Double(children.count), 0), 1)
    }

    public var currentChild: JobRecord? {
        guard let id = currentChildID else { return nil }
        return children.first(where: { $0.id == id })
    }

    public var isActive: Bool {
        guard let group else { return false }
        return !group.state.isTerminal
    }

    public var activeRunnerCount: Int {
        if usingPool { return poolActive.count }
        return isActive ? 1 : 0
    }

    /// 控制台按子任务切换：pool 的 runner 会保留到下一组 reset。
    public func runner(for childID: String) -> JobRunner? {
        if let runner = poolRunners[childID] { return runner }
        if currentChildID == childID { return runner }
        if children.count == 1 { return runner }
        return nil
    }

    public var groupTitle: String? {
        group?.title
    }

    // MARK: - Start

    public func startSingle(tool: LoadedTool, values: [String: FieldValue]) {
        guard !isActive, !runner.state.isActive else { return }
        resetCoordinator()
        usingPool = false

        let safeValues = tool.redactedValues(values)
        runtimeSecrets = tool.runtimeSecrets(from: values)
        let groupID = makeID(prefix: "g")
        let childID = makeID(prefix: "j")
        let path = tool.primaryPath(in: safeValues) ?? ""
        let itemLabel = path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
        let child = JobRecord(
            id: childID,
            toolID: tool.manifest.id,
            toolName: tool.manifest.name,
            groupID: groupID,
            itemLabel: itemLabel,
            values: safeValues
        )
        var group = JobGroupRecord(
            id: groupID,
            toolID: tool.manifest.id,
            toolName: tool.manifest.name,
            title: tool.manifest.name,
            state: .queued,
            childIDs: [childID],
            values: safeValues,
            isBatch: false
        )
        group.state = .running
        group.startedAt = Date()

        self.tool = tool
        self.group = group
        self.children = [child]
        self.pendingIDs = [childID]
        store.upsert(child)
        store.upsert(group)
        isBusy = true
        startNext()
    }

    public func startBatch(
        tool: LoadedTool,
        values: [String: FieldValue],
        files: [URL],
        outputDirectory: String?,
        skipExisting: Bool,
        stopOnError: Bool
    ) {
        guard !isActive, !runner.state.isActive, !files.isEmpty else { return }
        resetCoordinator()

        let safeValues = tool.redactedValues(values)
        runtimeSecrets = tool.runtimeSecrets(from: values)
        let groupID = makeID(prefix: "g")
        let batchInput = tool.manifest.batch?.input ?? tool.primaryPathKey ?? "video"
        let format = safeValues["format"]?.stringValue
            ?? tool.manifest.batch?.outputExtension
            ?? ""
        var children: [JobRecord] = []

        for file in files {
            let childID = makeID(prefix: "j")
            var childValues = safeValues
            childValues[batchInput] = .string(file.path)
            childValues["outputDir"] = .string(outputDirectory ?? "")

            var state: JobStatus = .queued
            var progress = 0.0
            var summary: String?
            var finishedAt: Date?
            if skipExisting && !format.isEmpty {
                let targetDirectory = (outputDirectory?.isEmpty == false)
                    ? URL(fileURLWithPath: outputDirectory!)
                    : file.deletingLastPathComponent()
                let target = targetDirectory
                    .appendingPathComponent(file.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension(format)
                if FileManager.default.fileExists(atPath: target.path) {
                    state = .skipped
                    progress = 1
                    summary = "已存在输出，跳过"
                    finishedAt = Date()
                }
            }

            children.append(
                JobRecord(
                    id: childID,
                    toolID: tool.manifest.id,
                    toolName: tool.manifest.name,
                    groupID: groupID,
                    itemLabel: file.lastPathComponent,
                    values: childValues,
                    state: state,
                    progress: progress,
                    finishedAt: finishedAt,
                    summary: summary
                )
            )
        }

        let group = JobGroupRecord(
            id: groupID,
            toolID: tool.manifest.id,
            toolName: tool.manifest.name,
            title: tool.manifest.batch?.title ?? "批量 · \(tool.manifest.name)",
            state: .running,
            startedAt: Date(),
            childIDs: children.map(\.id),
            values: safeValues,
            outputDirectory: outputDirectory,
            isBatch: true,
            stopOnError: stopOnError
        )

        self.tool = tool
        self.group = group
        self.children = children
        self.pendingIDs = children.filter { $0.state == .queued }.map(\.id)

        for child in children {
            store.upsert(child)
        }
        store.upsert(group)

        if pendingIDs.isEmpty {
            finishGroup()
            return
        }

        isBusy = true
        if usePool(for: tool, values: group.values) {
            usingPool = true
            poolPending = pendingIDs
            pendingIDs = []
            startPool()
        } else {
            startNext()
        }
    }

    public func resume(
        group original: JobGroupRecord,
        tool: LoadedTool,
        overrideValues: [String: FieldValue]? = nil
    ) {
        guard !isActive, !runner.state.isActive else { return }
        resetCoordinator()

        self.tool = tool
        self.group = original
        let existingChildren = store.children(of: original)
        self.children = existingChildren

        var pending: [String] = []
        var updatedChildren: [JobRecord] = []
        let batchInput = tool.manifest.batch?.input ?? tool.primaryPathKey ?? "video"
        let safeOverride = overrideValues.map { tool.redactedValues($0) }
        runtimeSecrets = overrideValues.map { tool.runtimeSecrets(from: $0) } ?? [:]

        for var child in existingChildren {
            if let safeOverride {
                if original.isBatch {
                    // 批量任务保留每个子任务自己的主输入和输出目录，只覆盖公共参数。
                    for (key, value) in safeOverride
                    where key != batchInput && key != "outputDir" {
                        child.values[key] = value
                    }
                } else {
                    child.values = safeOverride
                    if let path = tool.primaryPath(in: child.values) {
                        child.itemLabel = URL(fileURLWithPath: path).lastPathComponent
                    }
                }
            }

            switch child.state {
            case .succeeded, .skipped:
                break
            default:
                child.state = .queued
                child.errorMessage = nil
                child.isResumable = child.jobDirectory != nil
                pending.append(child.id)
            }
            updatedChildren.append(child)
            store.upsert(child)
        }

        var group = original
        if let safeOverride {
            group.values = safeOverride
        }
        group.state = .running
        group.finishedAt = nil
        group.errorMessage = nil
        group.currentChildID = nil
        group.startedAt = group.startedAt ?? Date()
        self.group = group
        self.children = updatedChildren
        self.pendingIDs = pending
        store.upsert(group)

        if pending.isEmpty {
            finishGroup()
            return
        }

        isBusy = true
        if original.isBatch, usePool(for: tool, values: group.values) {
            usingPool = true
            poolPending = pending
            pendingIDs = []
            startPool()
        } else {
            startNext()
        }
    }

    // MARK: - Control

    public func cancel(force: Bool = false) {
        guard var group, isActive else { return }
        isCancelling = true
        runToken = UUID()

        for id in pendingIDs {
            if var child = store.job(id: id) {
                child.state = .cancelled
                child.finishedAt = Date()
                child.progress = 0
                store.upsert(child)
            }
        }
        pendingIDs = []
        group.state = .cancelled
        group.finishedAt = Date()
        group.currentChildID = nil
        self.group = group
        store.upsert(group)
        refreshChildren()

        if usingPool {
            cancelPool(force: force)
            return
        }

        if runner.state.isActive {
            runner.cancel(force: force)
        } else {
            isBusy = false
            isCancelling = false
        }
    }

    public func forceCancel() {
        cancel(force: true)
    }

    // MARK: - Scheduling

    // MARK: - Non-GPU batch pool

    /// GPU 工具仍走单 runner 串行路径；没有 gpu 资源的批量任务才进入并发池。
    /// 手工校对有 checkpoint，继续沿用串行，避免多个等待中的子任务抢同一个控制台。
    private func usePool(for tool: LoadedTool, values: [String: FieldValue]) -> Bool {
        guard tool.manifest.batch != nil else { return false }
        let resources = resourceKeys(for: tool, values: values)
        guard !resources.contains("gpu") else { return false }
        return (values["reviewMode"]?.stringValue ?? "off") != "manual"
    }

    /// 云端转写不使用 GPU；批量云端任务按 network 并发（network=2），
    /// 本地转写仍保留 gpu=1 串行。其他工具按自身 resources 声明执行。
    private func resourceKeys(for tool: LoadedTool, values: [String: FieldValue]) -> [String] {
        let declared = tool.manifest.allResources
        guard values["backend"]?.stringValue == "cloud",
              declared.contains("gpu") else { return declared }
        var result = declared.filter { $0 != "gpu" }
        result.append("network")
        return Array(Set(result)).sorted()
    }

    private var poolLimit: Int {
        min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
    }

    private func startPool() {
        guard usingPool, let tool, let group, !group.state.isTerminal else { return }
        while poolActive.count < poolLimit, !poolPending.isEmpty {
            let childID = poolPending.removeFirst()
            guard let child = store.job(id: childID) else { continue }
            poolActive.insert(childID)
            launchPoolChild(child, tool: tool)
        }
        if poolActive.isEmpty && poolPending.isEmpty {
            finishGroup()
        }
    }

    private func launchPoolChild(_ child: JobRecord, tool: LoadedTool) {
        var queued = child
        queued.state = .queued
        queued.errorMessage = nil
        store.upsert(queued)

        let childRunner = JobRunner()
        poolRunners[child.id] = childRunner
        let resources = resourceKeys(for: tool, values: child.values)
        poolResources[child.id] = resources

        var bindings: [AnyCancellable] = []
        bindings.append(
            childRunner.$state.sink { [weak self] state in
                self?.handlePoolState(childID: child.id, state: state)
            }
        )
        bindings.append(
            childRunner.$progress.sink { [weak self] progress in
                guard let self, let index = self.children.firstIndex(where: { $0.id == child.id }) else { return }
                self.children[index].progress = progress
            }
        )
        poolBindings[child.id] = bindings

        let token = runToken
        Task { [weak self] in
            await ResourceScheduler.shared.acquire(resources)
            await MainActor.run {
                guard let self else {
                    Task { await ResourceScheduler.shared.release(resources) }
                    return
                }
                guard self.runToken == token,
                      self.usingPool,
                      let group = self.group,
                      !group.state.isTerminal else {
                    self.poolActive.remove(child.id)
                    self.poolResources.removeValue(forKey: child.id)
                    if var pending = self.store.job(id: child.id) {
                        pending.state = .cancelled
                        pending.finishedAt = Date()
                        self.store.upsert(pending)
                    }
                    Task { await ResourceScheduler.shared.release(resources) }
                    if self.poolActive.isEmpty && self.poolPending.isEmpty {
                        self.finishGroup()
                    }
                    return
                }

                var running = self.store.job(id: child.id) ?? queued
                running.state = .running
                running.startedAt = Date()
                running.finishedAt = nil
                self.store.upsert(running)
                if self.currentChildID == nil {
                    self.currentChildID = child.id
                    self.runner = childRunner
                }
                self.refreshChildren()

                childRunner.start(
                    tool: tool,
                    values: running.values,
                    jobDirectory: running.isResumable ? running.jobDirectory.map { URL(fileURLWithPath: $0) } : nil,
                    resume: running.isResumable,
                    secrets: self.runtimeSecrets
                )
            }
        }
    }

    private func handlePoolState(childID: String, state: JobRunner.State) {
        guard usingPool, let group else { return }
        guard let index = children.firstIndex(where: { $0.id == childID }) else { return }

        switch state {
        case .running:
            children[index].state = .running
            currentChildID = childID
            self.runner = poolRunners[childID] ?? runner
            var updated = group
            updated.currentChildID = childID
            updated.state = .running
            self.group = updated
            store.upsert(updated)

        case .waiting:
            children[index].state = .waiting
            var updated = group
            updated.state = .waiting
            updated.currentChildID = childID
            self.group = updated
            store.upsert(updated)

        case .succeeded, .failed, .cancelled:
            guard !poolTerminal.contains(childID) else { return }
            poolTerminal.insert(childID)
            handlePoolTerminal(childID: childID, state: state)

        case .idle:
            break
        }
    }

    private func handlePoolTerminal(childID: String, state: JobRunner.State) {
        guard let group, let childRunner = poolRunners[childID],
              var child = store.job(id: childID) else { return }

        child.progress = state == .succeeded ? 1 : childRunner.progress
        child.finishedAt = childRunner.finishedAt ?? Date()
        child.summary = childRunner.summary
        child.errorMessage = childRunner.errorMessage
        child.steps = childRunner.steps.map {
            JobStepRecord(id: $0.id, title: $0.title, state: $0.state)
        }
        child.artifacts = childRunner.artifacts
        child.jobDirectory = childRunner.jobDirectory?.path
        child.fingerprint = childRunner.fingerprint

        switch state {
        case .succeeded:
            child.state = .succeeded
            child.isResumable = false
        case .failed:
            child.state = .failed
            child.isResumable = child.jobDirectory != nil
        case .cancelled:
            child.state = .cancelled
        default:
            break
        }
        store.upsert(child)
        releasePoolChild(childID)

        if group.stopOnError, state == .failed {
            for id in poolActive {
                poolRunners[id]?.cancel()
            }
            for id in poolPending {
                if var pending = store.job(id: id) {
                    pending.state = .cancelled
                    pending.finishedAt = Date()
                    store.upsert(pending)
                }
            }
            poolPending = []
        }

        if poolActive.isEmpty && poolPending.isEmpty {
            finishGroup()
        } else {
            startPool()
        }
    }

    private func releasePoolChild(_ childID: String) {
        let resources = poolResources.removeValue(forKey: childID) ?? []
        poolActive.remove(childID)
        // 保留 poolRunners 供控制台切换；下一次 resetCoordinator 再清。
        poolBindings.removeValue(forKey: childID)

        if currentChildID == childID {
            if let next = children.first(where: { poolActive.contains($0.id) })?.id {
                currentChildID = next
                runner = poolRunners[next] ?? runner
            } else {
                currentChildID = nil
            }
        }

        if !resources.isEmpty {
            Task { await ResourceScheduler.shared.release(resources) }
        }
        refreshChildren()
    }

    private func cancelPool(force: Bool) {
        for id in poolPending {
            if var child = store.job(id: id) {
                child.state = .cancelled
                child.finishedAt = Date()
                child.progress = 0
                store.upsert(child)
            }
        }
        poolPending = []
        for id in poolActive {
            poolRunners[id]?.cancel(force: force)
        }
        if poolActive.isEmpty {
            finishGroup()
        }
    }

    private func bindRunner() {
        stateCancellable = runner.$state.sink { [weak self] state in
            guard let self else { return }
            self.handleRunnerState(state)
        }
        progressCancellable = runner.$progress.sink { [weak self] progress in
            guard let self else { return }
            guard let id = self.currentChildID,
                  let index = self.children.firstIndex(where: { $0.id == id }) else { return }
            self.children[index].progress = progress
        }
    }

    private func startNext() {
        guard var group, let tool else {
            finishGroup()
            return
        }
        guard !pendingIDs.isEmpty else {
            finishGroup()
            return
        }

        let childID = pendingIDs.removeFirst()
        guard let child = store.job(id: childID) else {
            startNext()
            return
        }

        let resume = child.isResumable && child.jobDirectory != nil
        currentChildID = childID
        terminalHandled = false
        isCancelling = false

        group.currentChildID = childID
        group.state = .running
        self.group = group
        store.upsert(group)

        var runningChild = child
        runningChild.state = .running
        runningChild.startedAt = Date()
        runningChild.finishedAt = nil
        runningChild.errorMessage = nil
        if !resume { runningChild.progress = 0 }
        store.upsert(runningChild)
        refreshChildren()

        resources = resourceKeys(for: tool, values: group.values)
        let requestedResources = resources
        let token = runToken

        Task { [weak self] in
            guard let self else { return }
            await ResourceScheduler.shared.acquire(requestedResources)
            await MainActor.run {
                guard self.runToken == token, let group = self.group, !group.state.isTerminal else {
                    Task { await ResourceScheduler.shared.release(requestedResources) }
                    return
                }
                self.launch(
                    tool: tool,
                    child: runningChild,
                    resume: resume
                )
            }
        }
    }

    private func launch(tool: LoadedTool, child: JobRecord, resume: Bool) {
        let existingDirectory = resume ? child.jobDirectory.map { URL(fileURLWithPath: $0) } : nil
        var updated = child
        updated.state = .running
        store.upsert(updated)

        runner.start(
            tool: tool,
            values: child.values,
            jobDirectory: existingDirectory,
            resume: resume,
            secrets: runtimeSecrets
        )

        if let dir = runner.jobDirectory {
            var record = store.job(id: child.id) ?? child
            record.jobDirectory = dir.path
            record.fingerprint = runner.fingerprint
            store.upsert(record)
            refreshChildren()
        }
    }

    private func handleRunnerState(_ state: JobRunner.State) {
        guard let group, let childID = currentChildID else { return }
        guard let index = children.firstIndex(where: { $0.id == childID }) else { return }

        switch state {
        case .running:
            if group.state != .running {
                var updatedGroup = group
                updatedGroup.state = .running
                self.group = updatedGroup
                store.upsert(updatedGroup)
            }
            children[index].state = .running

        case .waiting:
            children[index].state = .waiting
            var updatedGroup = group
            updatedGroup.state = .waiting
            self.group = updatedGroup
            store.upsert(updatedGroup)
            var child = children[index]
            child.state = .waiting
            store.upsert(child)

        case .succeeded, .failed, .cancelled:
            guard !terminalHandled else { return }
            terminalHandled = true
            handleTerminal(state: state)

        case .idle:
            break
        }
    }

    private func handleTerminal(state: JobRunner.State) {
        guard let group, let childID = currentChildID else { return }
        guard var child = store.job(id: childID) else { return }

        child.progress = state == .succeeded ? 1 : runner.progress
        child.finishedAt = runner.finishedAt ?? Date()
        child.summary = runner.summary
        child.errorMessage = runner.errorMessage
        child.steps = runner.steps.map {
            JobStepRecord(id: $0.id, title: $0.title, state: $0.state)
        }
        child.artifacts = runner.artifacts
        child.jobDirectory = runner.jobDirectory?.path

        switch state {
        case .succeeded:
            child.state = .succeeded
            child.isResumable = false
        case .failed:
            child.state = .failed
            child.isResumable = child.jobDirectory != nil
        case .cancelled:
            child.state = .cancelled
        default:
            break
        }

        store.upsert(child)
        releaseResources()
        isBusy = false
        currentChildID = nil
        refreshChildren()

        if state == .cancelled || isCancelling {
            var updated = group
            updated.state = .cancelled
            updated.finishedAt = Date()
            updated.currentChildID = nil
            self.group = updated
            store.upsert(updated)
            for id in pendingIDs {
                if var pending = store.job(id: id) {
                    pending.state = .cancelled
                    pending.finishedAt = Date()
                    store.upsert(pending)
                }
            }
            pendingIDs = []
            isCancelling = false
            refreshChildren()
            return
        }

        if state == .failed && group.stopOnError {
            var updated = group
            updated.state = .failed
            updated.finishedAt = Date()
            updated.currentChildID = nil
            updated.errorMessage = child.errorMessage
            self.group = updated
            store.upsert(updated)
            for id in pendingIDs {
                if var pending = store.job(id: id) {
                    pending.state = .cancelled
                    pending.finishedAt = Date()
                    store.upsert(pending)
                }
            }
            pendingIDs = []
            refreshChildren()
            return
        }

        var updated = group
        updated.currentChildID = nil
        self.group = updated
        store.upsert(updated)
        startNext()
    }

    private func finishGroup() {
        guard var group else { return }
        let all = store.children(of: group)
        let failedCount = all.filter { $0.state == .failed }.count
        let cancelledCount = all.filter { $0.state == .cancelled }.count

        group.finishedAt = Date()
        group.currentChildID = nil
        if cancelledCount == all.count && !all.isEmpty {
            group.state = .cancelled
        } else if failedCount > 0 {
            group.state = .failed
            group.errorMessage = "\(failedCount) 项失败"
        } else {
            group.state = .succeeded
        }

        self.group = group
        store.upsert(group)
        isBusy = false
        currentChildID = nil
        usingPool = false
        poolTerminal = []
        // 保留本组 poolRunners，让已结束任务仍能在控制台查看。
        poolBindings.removeAll()
        poolResources.removeAll()
        releaseResources()
        refreshChildren()
    }

    private func releaseResources() {
        guard !resources.isEmpty else { return }
        let releasing = resources
        resources = []
        Task {
            await ResourceScheduler.shared.release(releasing)
        }
    }

    private func refreshChildren() {
        guard let group else {
            children = []
            return
        }
        children = store.children(of: group)
    }

    private func resetCoordinator() {
        for runner in poolRunners.values where runner.state.isActive {
            runner.cancel(force: true)
        }
        poolRunners.removeAll()
        poolBindings.removeAll()
        poolResources.removeAll()
        poolActive.removeAll()
        poolPending = []
        poolTerminal = []
        usingPool = false

        stateCancellable?.cancel()
        progressCancellable?.cancel()
        runToken = UUID()
        pendingIDs = []
        children = []
        group = nil
        currentChildID = nil
        isBusy = false
        isCancelling = false
        terminalHandled = false
        resources = []
        runtimeSecrets = [:]
        bindRunner()
    }

    private func makeID(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }
}
