// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CrocShare",
    defaultLocalization: "fr",
    platforms: [.macOS("13.1")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/rive-app/rive-ios", from: "6.0.0"),
        // WebRTC pour les appels audio/vidéo + screen share. XCFramework
        // distribué en binaire (~50 Mo) — Apache 2.0, fork stable de Google.
        .package(url: "https://github.com/stasel/WebRTC.git", from: "125.0.0")
    ],
    targets: [
        .executableTarget(
            name: "CrocShare",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "RiveRuntime", package: "rive-ios"),
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Sources/CrocShare",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
