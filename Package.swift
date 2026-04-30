// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Corder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Corder", targets: ["Corder"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Corder",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Swifter", package: "swifter")
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
