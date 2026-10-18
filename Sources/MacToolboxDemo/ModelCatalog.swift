import Combine
import Foundation

@MainActor
final class ModelCatalog: ObservableObject {
    @Published var models: [String] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastBaseURL: String?

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        session = URLSession(configuration: configuration)
    }

    func fetch(baseURL: String, apiKey: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "请先填写 Base URL"
            return
        }

        guard let url = modelsURL(from: trimmed) else {
            errorMessage = "Base URL 格式不正确"
            return
        }

        isLoading = true
        errorMessage = nil
        models = []
        lastBaseURL = trimmed

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false

                if let error {
                    self.errorMessage = "获取模型失败：\(error.localizedDescription)"
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self.errorMessage = "获取模型失败（HTTP \(http.statusCode)）\(body.prefix(160))"
                    return
                }
                guard let data, let ids = Self.parseModelIDs(data), !ids.isEmpty else {
                    self.errorMessage = "端点没有返回模型列表；可以直接手动输入模型 ID"
                    return
                }
                self.models = ids
            }
        }.resume()
    }

    private func modelsURL(from baseURL: String) -> URL? {
        var base = baseURL
        if !base.contains("://") {
            base = "https://" + base
        }
        while base.hasSuffix("/") {
            base.removeLast()
        }

        let suffix: String
        if base.hasSuffix("/v1") || base.contains("/v1/") {
            suffix = "/models"
        } else {
            suffix = "/v1/models"
        }
        return URL(string: base + suffix)
    }

    private static func parseModelIDs(_ data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var ids: [String] = []

        if let array = json as? [String] {
            ids = array
        } else if let dict = json as? [String: Any] {
            if let dataArray = dict["data"] as? [[String: Any]] {
                ids = dataArray.compactMap { $0["id"] as? String }
            } else if let modelArray = dict["models"] as? [[String: Any]] {
                ids = modelArray.compactMap {
                    ($0["id"] as? String) ?? ($0["name"] as? String)
                }
            } else if let modelArray = dict["models"] as? [String] {
                ids = modelArray
            }
        } else if let array = json as? [[String: Any]] {
            ids = array.compactMap {
                ($0["id"] as? String) ?? ($0["name"] as? String)
            }
        }

        let cleaned = Array(Set(ids.map { $0.trimmingCharacters(in: .whitespaces) }))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return cleaned
    }
}
