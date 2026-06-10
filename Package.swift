// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CrocShare",
    platforms: [.macOS("13.1")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/rive-app/rive-ios", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "CrocShare",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "RiveRuntime", package: "rive-ios")
            ],
            path: "Sources/CrocShare"
        )
    ]
)
