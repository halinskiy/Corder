import XCTest
import AVFoundation
@testable import Corder

final class AudioMixerTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000,
                                       channels: 1,
                                       interleaved: false)!

    // Build a Float32 mono PCM buffer where every sample equals `value`.
    private func buffer(of value: Float, frames: Int) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        guard let dst = buf.floatChannelData?[0] else { return buf }
        for i in 0..<frames { dst[i] = value }
        return buf
    }

    private func peak(_ buf: AVAudioPCMBuffer) -> Float {
        guard let dst = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        var p: Float = 0
        for i in 0..<n {
            let abs = dst[i] < 0 ? -dst[i] : dst[i]
            if abs > p { p = abs }
        }
        return p
    }

    // MARK: - The behaviour we actually care about

    func test_mix_keepsLoudUserAtFullLevel_whenOtherStreamIsSilent() {
        // Real-world case: user talks at peak ~0.5 into the mic, system
        // stream has nothing on it. The buggy /N mixer would drop the user
        // to 0.25; the fixed peak-normalised mixer must keep it at 0.5.
        let mic    = buffer(of: 0.5, frames: 1_000)
        let system = buffer(of: 0.0, frames: 1_000)

        let mixed = AudioMixer.mix(buffers: [mic, system], format: format)

        XCTAssertEqual(peak(mixed), 0.5, accuracy: 0.001)
    }

    func test_mix_normalisesDownWhenSumWouldClip() {
        // Both streams hot: 0.7 + 0.6 = 1.3 sum, must scale back to 0.98.
        let a = buffer(of: 0.7, frames: 1_000)
        let b = buffer(of: 0.6, frames: 1_000)

        let mixed = AudioMixer.mix(buffers: [a, b], format: format)

        XCTAssertEqual(peak(mixed), 0.98, accuracy: 0.001)
    }

    func test_mix_neverClipsAbove0_98() {
        // Three loud sources — sum 2.4. Final peak still capped at 0.98.
        let a = buffer(of: 0.8, frames: 100)
        let b = buffer(of: 0.8, frames: 100)
        let c = buffer(of: 0.8, frames: 100)

        let mixed = AudioMixer.mix(buffers: [a, b, c], format: format)

        XCTAssertLessThanOrEqual(peak(mixed), 0.98 + 0.001)
    }

    func test_mix_handlesDifferentLengths() {
        // Output length = max input length. Shorter buffer's tail is
        // implicitly silent.
        let short = buffer(of: 0.4, frames: 100)
        let long  = buffer(of: 0.0, frames: 1_000)

        let mixed = AudioMixer.mix(buffers: [short, long], format: format)

        XCTAssertEqual(Int(mixed.frameLength), 1_000)
        XCTAssertEqual(peak(mixed), 0.4, accuracy: 0.001)
    }
}
