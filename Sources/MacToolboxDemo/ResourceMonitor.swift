import Combine
import Foundation
#if canImport(ToolboxCore)
import ToolboxCore
#endif

@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var capacities: [String: Int] = [:]
    @Published private(set) var usage: [String: Int] = [:]

    private var task: Task<Void, Never>?

    init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refresh() async {
        let snapshot = await ResourceScheduler.shared.snapshot()
        capacities = snapshot.capacities
        usage = snapshot.usage
    }
}
