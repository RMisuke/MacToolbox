import Foundation

/// 原生工具（nativeView）的单一注册点。
///
/// 新增原生工具时必须：
/// 1. 在这里加 case + displayName；
/// 2. 在 ToolDetailView.nativeBody 里加对应 SwiftUI 视图；
/// 3. manifest 的 nativeView 使用 rawValue，并同时声明 run/agent。
///
/// 这样校验、详情路由和文档都只依赖一份枚举，避免 whitelist 与 switch 漂移。
public enum NativeToolKind: String, CaseIterable, Sendable {
    case homebrew
    case imageOCR

    public var displayName: String {
        switch self {
        case .homebrew: return "Homebrew 管理器"
        case .imageOCR: return "图片 OCR"
        }
    }

    public var summary: String {
        switch self {
        case .homebrew:
            return "SwiftUI 原生 Homebrew 软件包/维护界面；CLI 走 brew 协议工具。"
        case .imageOCR:
            return "SwiftUI 原生 VisionKit OCR 界面；CLI 走 Vision 助手。"
        }
    }

    /// 原生视图是否接收 LoadedTool（需要读取 manifest 名称/图标时传 true）。
    public var needsTool: Bool {
        switch self {
        case .imageOCR: return true
        case .homebrew: return false
        }
    }
}

public extension ToolManifest {
    var nativeKind: NativeToolKind? {
        guard let nativeView, !nativeView.isEmpty else { return nil }
        return NativeToolKind(rawValue: nativeView)
    }
}
