// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppleTreeUI",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AppleTreeUI",
            targets: ["AppleTreeUI"]
        )
    ],
    dependencies: [
        .package(path: "../AppleTreeCore")
    ],
    targets: [
        .target(
            name: "AppleTreeUI",
            dependencies: ["AppleTreeCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AppleTreeUITests",
            dependencies: ["AppleTreeUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
