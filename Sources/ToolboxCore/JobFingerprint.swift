import CryptoKit
import Foundation

/// 任务缓存指纹：输入值 + 输入文件元信息 + 工具版本/工具文件内容。
/// 只用于判断旧产物是否还能复用，不写入任何敏感明文。
public enum JobFingerprintBuilder {
    public static func make(tool: LoadedTool, values: [String: FieldValue]) -> String {
        var hasher = SHA256()
        update(&hasher, "mactoolbox-fingerprint-v1")
        update(&hasher, tool.manifest.id)
        update(&hasher, tool.manifest.version)
        update(&hasher, toolDigest(tool.directory))

        var stableValues = values
        for key in tool.secretKeys {
            stableValues.removeValue(forKey: key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(stableValues) {
            hasher.update(data: data)
        }

        let fileFields = tool.manifest.inputs
            .filter { $0.type == "file" }
            .map(\.key)
            .sorted()
        for key in fileFields {
            let path = values[key]?.stringValue ?? ""
            guard !path.isEmpty else { continue }
            update(&hasher, "file|\(key)|\(path)")
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                update(&hasher, "\(size)|\(modified)")
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func short(_ fingerprint: String) -> String {
        String(fingerprint.prefix(10))
    }

    private static func toolDigest(_ directory: URL) -> String {
        var hasher = SHA256()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return "unreadable" }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == "__pycache__" {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ["pyc", "log", "tmp", "ds_store"].contains(ext) { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            files.append(url)
        }

        for url in files.sorted(by: { $0.path < $1.path }) {
            let relative = url.path.replacingOccurrences(of: directory.path, with: "")
            update(&hasher, relative)
            guard let data = try? Data(contentsOf: url) else { continue }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, _ value: String) {
        hasher.update(data: Data(value.utf8))
        hasher.update(data: Data([0]))
    }
}
