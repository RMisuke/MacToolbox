import Darwin
import Foundation

/// 与 Python `toolbox_spec.ResourceLocks` 共用同一批 flock 文件。
///
/// GUI 的 ResourceScheduler 和 CLI/Agent 是不同进程；只靠各自内存计数
/// 会同时抢 GPU。这里把容量落成 `Locks/<resource>-<slot>.lock`，
/// 进程崩溃时内核自动释放，不会留下永久死锁。
public final class CrossProcessResourceLock: @unchecked Sendable {
    public let resource: String
    public let slot: Int
    public let path: String
    private var descriptor: Int32

    init(resource: String, slot: Int, path: String, descriptor: Int32) {
        self.resource = resource
        self.slot = slot
        self.path = path
        self.descriptor = descriptor
    }

    public func release() {
        guard descriptor >= 0 else { return }
        _ = Self.setLock(descriptor, type: Int16(F_UNLCK))
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    fileprivate static func setLock(_ descriptor: Int32, type: Int16) -> Bool {
        var lock = Darwin.flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return Darwin.fcntl(descriptor, F_SETLK, &lock) == 0
    }

    deinit {
        release()
    }
}

public enum CrossProcessResourceLocks {
    public static func capacities() -> [String: Int] {
        [
            "gpu": 1,
            "network": 2,
            "cpu": max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        ]
    }

    public static func lockDirectory() -> URL {
        ToolboxPaths.applicationSupport.appendingPathComponent("Locks", isDirectory: true)
    }

    /// 按资源字典序逐个获取；与 Python 侧顺序一致，避免交叉死锁。
    /// 超时返回已获取的部分（调用方会记录日志并继续），不会卡死 App。
    public static func acquire(
        _ resources: [String],
        timeout: TimeInterval = 3600
    ) async -> [String: CrossProcessResourceLock] {
        let keys = Array(Set(resources.map { $0.lowercased() })).sorted()
        guard !keys.isEmpty else { return [:] }
        let directory = lockDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let deadline = Date().addingTimeInterval(timeout)
        var acquired: [String: CrossProcessResourceLock] = [:]
        let capacities = capacities()

        for key in keys {
            let capacity = max(1, capacities[key] ?? 1)
            var lock: CrossProcessResourceLock?
            while lock == nil {
                for slot in 0..<capacity {
                    if let candidate = tryLock(resource: key, slot: slot, directory: directory) {
                        lock = candidate
                        break
                    }
                }
                guard lock == nil else { break }
                if Date() >= deadline {
                    release(acquired)
                    return [:]
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if let lock {
                acquired[key] = lock
            }
        }
        return acquired
    }

    public static func release(_ locks: [String: CrossProcessResourceLock]) {
        for lock in locks.values {
            lock.release()
        }
    }

    private static func tryLock(
        resource: String,
        slot: Int,
        directory: URL
    ) -> CrossProcessResourceLock? {
        let path = directory
            .appendingPathComponent("\(resource)-\(slot).lock")
            .path
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        )
        guard descriptor >= 0 else { return nil }
        guard CrossProcessResourceLock.setLock(descriptor, type: Int16(F_WRLCK)) else {
            _ = Darwin.close(descriptor)
            return nil
        }
        _ = Darwin.ftruncate(descriptor, 0)
        let payload = "\(getpid()) \(Int(Date().timeIntervalSince1970))\n"
        payload.withCString { pointer in
            _ = Darwin.write(descriptor, pointer, strlen(pointer))
        }
        return CrossProcessResourceLock(
            resource: resource,
            slot: slot,
            path: path,
            descriptor: descriptor
        )
    }
}
