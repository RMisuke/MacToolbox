import Foundation

/// 把旧 preferences / records / job config 里残留的 secret 搬进 Keychain，
/// 并从持久化文件里抹掉明文。只处理工具 manifest 标记为 secret 的字段。
@MainActor
public enum SecretMigrator {
    @discardableResult
    public static func migrate(tools: [LoadedTool], store: JobStore) -> Int {
        var migrated = 0

        for tool in tools {
            let secretKeys = Set(tool.secretKeys)
            guard !secretKeys.isEmpty else { continue }

            for record in store.jobs where record.toolID == tool.id {
                var updated = record
                var changed = false
                for key in secretKeys {
                    let value = updated.values[key]?.stringValue ?? ""
                    guard !value.isEmpty else { continue }
                    SecretStore.set(value, toolID: tool.id, key: key)
                    updated.values[key] = .string("")
                    changed = true
                    migrated += 1
                }
                if changed {
                    store.upsert(updated)
                }
                if let path = updated.jobDirectory {
                    migrated += scrubConfig(
                        URL(fileURLWithPath: path).appendingPathComponent("config.json"),
                        toolID: tool.id,
                        keys: secretKeys
                    )
                }
            }

            for group in store.groups where group.toolID == tool.id {
                var updated = group
                var changed = false
                for key in secretKeys {
                    if let value = updated.values[key]?.stringValue, !value.isEmpty {
                        SecretStore.set(value, toolID: tool.id, key: key)
                        updated.values[key] = .string("")
                        changed = true
                        migrated += 1
                    }
                }
                if changed {
                    store.upsert(updated)
                }
            }
        }

        let doctorConfig = ToolboxPaths.temp
            .appendingPathComponent("doctor", isDirectory: true)
            .appendingPathComponent("config.json")
        if let tool = tools.first {
            migrated += scrubConfig(doctorConfig, toolID: tool.id, keys: Set(tool.secretKeys))
        }
        return migrated
    }

    private static func scrubConfig(_ url: URL, toolID: String, keys: Set<String>) -> Int {
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        var count = 0
        for key in keys {
            guard let value = json[key] as? String, !value.isEmpty else { continue }
            SecretStore.set(value, toolID: toolID, key: key)
            json[key] = ""
            count += 1
        }
        guard count > 0,
              let encoded = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return 0 }
        try? encoded.write(to: url)
        return count
    }
}
