import AppKit
import SwiftUI

/// 主界面左上角的品牌图标。直接读 bundle 里的 AppIcon.icns，
/// 不依赖 NSApp.applicationIconImage（在未注册/缓存旧的启动方式下可能是通用图标）。
struct AppBrandIcon: View {
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let image = AppIconAsset.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: size * 0.44, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 4, y: 2)
    }
}

private enum AppIconAsset {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
