import Foundation

enum BrewParser {
    static func packages(infoData: Data, outdatedData: Data?) throws -> [BrewPackage] {
        guard let root = try JSONSerialization.jsonObject(with: infoData) as? [String: Any] else {
            throw BrewError.commandFailed("brew info 返回的不是 JSON 对象")
        }
        let outdated = parseOutdated(outdatedData)
        var packages: [BrewPackage] = []

        for item in root["formulae"] as? [[String: Any]] ?? [] {
            if let package = parseFormula(item, outdated: outdated) {
                packages.append(package)
            }
        }
        for item in root["casks"] as? [[String: Any]] ?? [] {
            if let package = parseCask(item, outdated: outdated) {
                packages.append(package)
            }
        }

        var dependents: [String: [String]] = [:]
        for package in packages {
            for dependency in package.dependencies {
                dependents[dependency, default: []].append(package.name)
                if let short = dependency.split(separator: "/").last {
                    dependents[String(short), default: []].append(package.name)
                }
            }
        }

        packages = packages.map { package in
            var copy = package
            let fromFull = dependents[package.fullName] ?? []
            let fromName = dependents[package.name] ?? []
            copy.dependents = Array(Set(fromFull + fromName)).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            return copy
        }
        return packages.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func parseFormula(
        _ item: [String: Any],
        outdated: [String: OutdatedEntry]
    ) -> BrewPackage? {
        guard let name = item["name"] as? String else { return nil }
        let fullName = item["full_name"] as? String ?? name
        let installedArray = item["installed"] as? [[String: Any]] ?? []
        let installed = installedArray.first
        let installedVersion = installed?["version"] as? String ?? ""
        let versions = item["versions"] as? [String: Any] ?? [:]
        let stable = versions["stable"] as? String ?? installedVersion
        let entry = outdated[name] ?? outdated[fullName]
        let latest = entry?.currentVersion ?? stable
        let infoOutdated = item["outdated"] as? Bool ?? false

        var dependencies = item["dependencies"] as? [String] ?? []
        if let runtime = installed?["runtime_dependencies"] as? [[String: Any]] {
            for dep in runtime {
                if let depName = dep["full_name"] as? String, !dependencies.contains(depName) {
                    dependencies.append(depName)
                }
            }
        }

        var installedAt: Date?
        if let time = installed?["time"] as? Double {
            installedAt = Date(timeIntervalSince1970: time)
        }

        return BrewPackage(
            kind: .formula,
            name: name,
            fullName: fullName,
            displayName: name,
            description: item["desc"] as? String ?? "",
            homepage: item["homepage"] as? String ?? "",
            tap: item["tap"] as? String ?? "",
            license: item["license"] as? String ?? "",
            installedVersion: installedVersion,
            latestVersion: latest,
            isOutdated: infoOutdated || entry != nil,
            isPinned: item["pinned"] as? Bool ?? false,
            installedOnRequest: installed?["installed_on_request"] as? Bool ?? false,
            isDeprecated: item["deprecated"] as? Bool ?? false,
            isDisabled: item["disabled"] as? Bool ?? false,
            dependencies: dependencies,
            dependents: [],
            caveats: BrewRunner.stripANSI(item["caveats"] as? String ?? ""),
            installedAt: installedAt
        )
    }

    private static func parseCask(
        _ item: [String: Any],
        outdated: [String: OutdatedEntry]
    ) -> BrewPackage? {
        guard let token = item["token"] as? String else { return nil }
        let fullName = item["full_token"] as? String ?? token
        let names = item["name"] as? [String] ?? []
        let displayName = names.first ?? token
        let installed = item["installed"] as? String ?? ""
        let current = item["version"] as? String ?? installed
        let entry = outdated[token] ?? outdated[fullName]
        let latest = entry?.currentVersion ?? current

        var dependencies: [String] = []
        if let depends = item["depends_on"] as? [String: Any] {
            for key in ["formula", "cask"] {
                if let list = depends[key] as? [String] {
                    dependencies.append(contentsOf: list)
                } else if let single = depends[key] as? String {
                    dependencies.append(single)
                }
            }
        }

        var installedAt: Date?
        if let time = item["installed_time"] as? Double {
            installedAt = Date(timeIntervalSince1970: time)
        }

        return BrewPackage(
            kind: .cask,
            name: token,
            fullName: fullName,
            displayName: displayName,
            description: item["desc"] as? String ?? "",
            homepage: item["homepage"] as? String ?? "",
            tap: item["tap"] as? String ?? "",
            license: "",
            installedVersion: installed,
            latestVersion: latest,
            isOutdated: (item["outdated"] as? Bool ?? false) || entry != nil,
            isPinned: item["pinned"] as? Bool ?? false,
            installedOnRequest: true,
            isDeprecated: item["deprecated"] as? Bool ?? false,
            isDisabled: item["disabled"] as? Bool ?? false,
            dependencies: dependencies,
            dependents: [],
            caveats: BrewRunner.stripANSI(item["caveats"] as? String ?? ""),
            installedAt: installedAt
        )
    }

    private struct OutdatedEntry {
        let installedVersion: String
        let currentVersion: String
    }

    private static func parseOutdated(_ data: Data?) -> [String: OutdatedEntry] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: OutdatedEntry] = [:]
        for item in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String,
                  let current = item["current_version"] as? String else { continue }
            let installed = (item["installed_versions"] as? [String])?.first ?? ""
            result[name] = OutdatedEntry(installedVersion: installed, currentVersion: current)
        }
        for item in root["casks"] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String,
                  let current = item["current_version"] as? String else { continue }
            let installed = (item["installed_versions"] as? [String])?.first ?? ""
            result[name] = OutdatedEntry(installedVersion: installed, currentVersion: current)
        }
        return result
    }
}
