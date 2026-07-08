// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppleTreeCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AppleTreeCore",
            targets: ["AppleTreeCore"]
        ),
        .executable(
            name: "scanbench",
            targets: ["ScanBench"]
        )
    ],
    targets: [
        .target(
            name: "AppleTreeCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "ScanBench",
            dependencies: ["AppleTreeCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AppleTreeCoreTests",
            dependencies: ["AppleTreeCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
