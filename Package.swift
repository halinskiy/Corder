// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Corder",
    // 14.2 is the floor for the Core Audio process-tap API
    // (AudioHardwareCreateProcessTap + CATapDescription) used for
    // capturing call audio that SCStream can't see.
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "Corder", targets: ["Corder"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.4"),
        // On-device speaker diarization (pyannote community-1 + WeSpeaker
        // + VBx, Core ML). Replaces Gemini's unreliable single-mic
        // diarization. No transitive deps, no binary framework to
        // re-sign; models auto-download (~130 MB once) to
        // ~/Library/Application Support/FluidAudio/Models/.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.5"),
        // Local Whisper (Apple-Silicon-native, Core ML under the hood).
        // Third ASR provider — $0/hour after the one-time multilingual
        // model download (~1.5 GB) cached under AppPaths.modelsDir. Adds
        // ~50-100 MB of Core ML runtime to the bundle; the model itself
        // is fetched on-demand the first time the user flips to the
        // `whisperLocal` provider, not bundled. Apple Silicon only —
        // Intel callers fall back to Gemini at the pipeline level.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // Supabase backend client (Auth + PostgREST + Storage + Realtime).
        // Replaces the GRDB local DB / loopback Google OAuth /
        // Cloudflare Worker signup chain. Used for account-scoped
        // meetings, transcripts, and audio uploads.
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Corder",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Swifter", package: "swifter"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Supabase", package: "supabase-swift")
            ],
            resources: [
                .copy("Resources/web"),
                .copy("Resources/icons")
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
