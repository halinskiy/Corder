import XCTest
@testable import Corder

/// Developer benchmark for the on-device ASR path. Skipped unless
/// `CORDER_BENCH_AUDIO` is set, so it never runs in CI. It drives the REAL
/// `LocalWhisperTranscriber.transcribe` (VAD, chunk scheduler, projection),
/// one task per track like the pipeline's dual-track fork, and writes a JSON
/// report. Environment:
///   CORDER_BENCH_AUDIO     colon-separated wav paths (the tracks of one meeting)
///   CORDER_BENCH_VARIANTS  comma-separated `Variant` raw values
///   CORDER_BENCH_RUNS      repetitions per variant (default 1)
///   CORDER_BENCH_LANG      forced ISO language, empty = auto-detect
///   CORDER_BENCH_OUT       JSON output path
final class LocalASRBenchTests: XCTestCase {
    func testBench() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let audioList = env["CORDER_BENCH_AUDIO"], !audioList.isEmpty else {
            throw XCTSkip("set CORDER_BENCH_AUDIO to run the on-device ASR benchmark")
        }
        let audios = audioList.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let variants = (env["CORDER_BENCH_VARIANTS"] ?? "").split(separator: ",")
            .compactMap { LocalWhisperTranscriber.Variant(rawValue: String($0)) }
        XCTAssertFalse(variants.isEmpty, "no known variants in CORDER_BENCH_VARIANTS")
        let runs = max(1, Int(env["CORDER_BENCH_RUNS"] ?? "1") ?? 1)
        let lang = env["CORDER_BENCH_LANG"].flatMap { $0.isEmpty ? nil : $0 }
        let outPath = env["CORDER_BENCH_OUT"] ?? "/tmp/corder-asr-bench.json"

        var report: [[String: Any]] = []
        for variant in variants {
            // Download + the one-time compile with the prewarm budget first, so
            // the timed runs measure a warm model the way a user's second
            // transcript does, not a cold compile falling back to the GPU.
            let tPrep = Date()
            try await LocalWhisperTranscriber.downloadOnly(variant)
            let prepSec = Date().timeIntervalSince(tPrep)
            let tLoad = Date()
            try await LocalWhisperTranscriber.ensureModelReady(variant)
            let loadSec = Date().timeIntervalSince(tLoad)

            for run in 0..<runs {
                let t0 = Date()
                let tracks = try await withThrowingTaskGroup(
                    of: (String, [GeminiTranscriber.Turn], Double).self
                ) { group -> [(String, [GeminiTranscriber.Turn], Double)] in
                    for audio in audios {
                        group.addTask { @MainActor in
                            let t = Date()
                            let turns = try await WhisperTranscriber.$languageOverride.withValue(lang) {
                                try await LocalWhisperTranscriber.transcribe(
                                    audioURL: audio, mode: .single, variant: variant, initialPrompt: nil)
                            }
                            return (audio.path, turns, Date().timeIntervalSince(t))
                        }
                    }
                    var collected: [(String, [GeminiTranscriber.Turn], Double)] = []
                    for try await item in group { collected.append(item) }
                    return collected
                }
                let wall = Date().timeIntervalSince(t0)
                var entry: [String: Any] = [
                    "variant": variant.rawValue,
                    "run": run,
                    "lang": lang ?? "auto",
                    "prep_sec": prepSec,
                    "load_sec": loadSec,
                    "wall_sec": wall,
                ]
                entry["tracks"] = tracks.sorted { $0.0 < $1.0 }.map { path, turns, sec -> [String: Any] in
                    [
                        "path": path,
                        "sec": sec,
                        "turns": turns.count,
                        "text": turns.map(\.text).joined(separator: "\n"),
                        "first_ms": turns.first?.startMs ?? -1,
                        "last_ms": turns.last?.endMs ?? -1,
                    ]
                }
                report.append(entry)
                print("BENCH \(variant.rawValue) run \(run) lang \(lang ?? "auto"): wall \(String(format: "%.1f", wall)) s, tracks \(tracks.map { "\($0.1.count) turns in \(String(format: "%.1f", $0.2)) s" })")
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: outPath))
            }
        }
    }
}
