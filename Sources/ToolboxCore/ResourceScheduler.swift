import Foundation

/// 全局资源调度器。批量子任务与单任务共用同一份容量：
/// gpu = 1（whisper 必须串行）、network = 2、cpu = 核数 - 1。
public actor ResourceScheduler {
    public static let shared = ResourceScheduler()

    public struct Snapshot: Sendable {
        public let capacities: [String: Int]
        public let usage: [String: Int]
    }

    private struct Waiter {
        let id: UUID
        let resources: [String]
        let continuation: CheckedContinuation<Void, Never>
    }

    private var capacities: [String: Int]
    private var usage: [String: Int] = [:]
    private var waiters: [Waiter] = []
    /// 每个资源对应一栈跨进程锁；release(resources) 按栈弹出，保持与本地计数一致。
    private var crossProcessLocks: [String: [CrossProcessResourceLock]] = [:]

    public init() {
        let cpuCapacity = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        capacities = [
            "gpu": 1,
            "network": 2,
            "cpu": cpuCapacity
        ]
    }

    public func acquire(_ resources: [String]) async {
        let keys = normalize(resources)
        guard !keys.isEmpty else { return }

        // 先拿跨进程锁，再排队本地容量；这样 GUI 与 CLI 共享 gpu=1 / network=2。
        let acquired = await CrossProcessResourceLocks.acquire(keys)
        if acquired.isEmpty {
            NSLog("ResourceScheduler: 跨进程资源锁超时，继续执行（%@）", keys.joined(separator: ","))
        } else {
            for (key, lock) in acquired {
                crossProcessLocks[key, default: []].append(lock)
            }
        }

        if canAcquire(keys) {
            take(keys)
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: UUID(), resources: keys, continuation: continuation))
        }
    }

    public func release(_ resources: [String]) {
        let keys = normalize(resources)
        guard !keys.isEmpty else { return }

        for key in keys {
            usage[key] = max(0, (usage[key] ?? 0) - 1)
            if var stack = crossProcessLocks[key], let lock = stack.popLast() {
                lock.release()
                if stack.isEmpty {
                    crossProcessLocks.removeValue(forKey: key)
                } else {
                    crossProcessLocks[key] = stack
                }
            }
        }
        drainWaiters()
    }

    public func snapshot() -> Snapshot {
        Snapshot(capacities: capacities, usage: usage)
    }

    public func setCapacity(_ resource: String, _ capacity: Int) {
        capacities[resource] = max(0, capacity)
        drainWaiters()
    }

    // MARK: - Internals

    private func normalize(_ resources: [String]) -> [String] {
        Array(Set(resources.map { $0.lowercased() })).sorted()
    }

    private func capacity(for resource: String) -> Int {
        capacities[resource] ?? 1
    }

    private func canAcquire(_ resources: [String]) -> Bool {
        resources.allSatisfy { (usage[$0] ?? 0) < capacity(for: $0) }
    }

    private func take(_ resources: [String]) {
        for key in resources {
            usage[key, default: 0] += 1
        }
    }

    private func drainWaiters() {
        guard !waiters.isEmpty else { return }
        var remaining: [Waiter] = []
        for waiter in waiters {
            if canAcquire(waiter.resources) {
                take(waiter.resources)
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}
