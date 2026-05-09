import XCTest
import AVFoundation
@testable import Corder

final class DiarizerTests: XCTestCase {

    // MARK: - Fixture helper

    /// Writes a 16 kHz mono Float32 WAV to a temp URL where each sample
    /// equals `level`. Stable enough RMS for the channel-gate to read.
    private func writeMonoTone(level: Float, durationSec: Double) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(durationSec * 16_000)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        if let dst = buf.floatChannelData?[0] {
            for i in 0..<Int(frames) { dst[i] = level }
        }
        try file.write(from: buf)
        return url
    }

    private func cleanup(_ urls: [URL]) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: - Tests

    func test_userMicDominance_returnsTrue_whenMicLouderBy_2x() throws {
        // Channel gate threshold: mic_RMS > 2 × system_RMS && mic_RMS > 0.005.
        // 0.30 vs 0.05 ratio is 6×, well over the 2× cutoff.
        let micURL    = try writeMonoTone(level: 0.30, durationSec: 1.0)
        let systemURL = try writeMonoTone(level: 0.05, durationSec: 1.0)
        defer { cleanup([micURL, systemURL]) }

        let votes = try Diarizer.userMicDominance(
            segments: [(start: 0.1, end: 0.9)],
            userPath: micURL,
            otherPath: systemURL
        )
        XCTAssertEqual(votes, [true])
    }

    func test_userMicDominance_returnsFalse_whenSystemLouder() throws {
        // Inverse: system loud, mic quiet → not the user.
        let micURL    = try writeMonoTone(level: 0.05, durationSec: 1.0)
        let systemURL = try writeMonoTone(level: 0.30, durationSec: 1.0)
        defer { cleanup([micURL, systemURL]) }

        let votes = try Diarizer.userMicDominance(
            segments: [(start: 0.1, end: 0.9)],
            userPath: micURL,
            otherPath: systemURL
        )
        XCTAssertEqual(votes, [false])
    }

    func test_userMicDominance_returnsFalse_whenMicTooQuiet() throws {
        // Mic louder than system in ratio (4×) but below the absolute floor
        // (0.005). Don't classify silence as the user just because the
        // system stream is even quieter.
        let micURL    = try writeMonoTone(level: 0.002, durationSec: 1.0)
        let systemURL = try writeMonoTone(level: 0.0005, durationSec: 1.0)
        defer { cleanup([micURL, systemURL]) }

        let votes = try Diarizer.userMicDominance(
            segments: [(start: 0.1, end: 0.9)],
            userPath: micURL,
            otherPath: systemURL
        )
        XCTAssertEqual(votes, [false])
    }

    func test_userMicDominance_perSegment_independence() throws {
        // Two segments, same audio file pair. Each window is evaluated
        // independently — the gate result for [0.1, 0.5] doesn't carry
        // over to [0.5, 0.9].
        let micURL    = try writeMonoTone(level: 0.30, durationSec: 1.0)
        let systemURL = try writeMonoTone(level: 0.05, durationSec: 1.0)
        defer { cleanup([micURL, systemURL]) }

        let votes = try Diarizer.userMicDominance(
            segments: [
                (start: 0.1, end: 0.5),
                (start: 0.5, end: 0.9),
            ],
            userPath: micURL,
            otherPath: systemURL
        )
        XCTAssertEqual(votes, [true, true])
    }
}
