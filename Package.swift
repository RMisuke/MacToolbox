// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacToolboxDemo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacToolboxDemo", targets: ["MacToolboxDemo"])
    ],
    targets: [
        .target(
            name: "ToolboxCore",
            path: "Sources/ToolboxCore"
        ),
        .executableTarget(
            name: "MacToolboxDemo",
            dependencies: ["ToolboxCore"],
            path: "Sources/MacToolboxDemo"
        )
    ],
    swiftLanguageVersions: [.v5]
)
