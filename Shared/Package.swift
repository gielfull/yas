// swift-tools-version: 6.0
import PackageDescription

// Linked into both the host app and the root system extension, so it must stay
// dependency-free.
let package = Package(
    name: "YASShared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YASShared", targets: ["YASShared"]),
    ],
    targets: [
        .target(
            name: "YASShared",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "YASSharedTests",
            dependencies: ["YASShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
