// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Corder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Corder", targets: ["Corder"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.4")
    ],
    targets: [
        .executableTarget(
            name: "Corder",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Swifter", package: "swifter"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .copy("Resources/web")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "CorderTests",
            dependencies: ["Corder"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
