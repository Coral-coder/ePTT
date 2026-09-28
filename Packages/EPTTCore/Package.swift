// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EPTTCore",
    platforms: [.iOS(.v16), .watchOS(.v9), .macOS(.v13)],
    products: [
        .library(name: "EPTTCore", targets: ["EPTTCore"]),
    ],
    dependencies: [
        // CryptoKit on Apple platforms; swift-crypto provides the same API on Linux (CI).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
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
