// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EPTTCore",
    // Protocol 2 needs CryptoKit's ML-KEM-1024 (iOS / watchOS / macOS 26).
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "EPTTCore", targets: ["EPTTCore", "EPTTLegacy", "EPTTCompat"]),
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
        // Protocol 1, unchanged from the builds before protocol 2, so contacts who haven't
        // updated can still be reached (PROTOCOL.md §10.1). Only EPTTCompat uses it.
        .target(
            name: "EPTTLegacy",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(name: "EPTTCompat", dependencies: ["EPTTCore", "EPTTLegacy"]),
        .testTarget(
            name: "EPTTCoreTests",
            dependencies: ["EPTTCore", "EPTTCompat", "EPTTLegacy"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
