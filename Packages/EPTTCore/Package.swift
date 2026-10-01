// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EPTTCore",
    // Protocol 2 needs CryptoKit's ML-KEM-1024 (iOS / watchOS / macOS 26).
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EPTTCore", targets: ["EPTTCore"]),
    ],
    dependencies: [
        // CryptoKit on Apple platforms; swift-crypto provides the same API on Linux (CI).
        .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "EPTTCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "EPTTCoreTests",
            dependencies: ["EPTTCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
