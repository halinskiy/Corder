import Foundation
import AVFoundation
import Combine

/// Observable singleton fed by CaptureEngine on every audio buffer it
/// receives. Drives the floating recording HUD (RecordingHUDPanel).
///
/// We expose two channels — `micLevel` and `systemLevel` — both clamped
/// to 0…1 with a fast attack / slow release envelope so the bars don't
/// look spasmodic. CaptureEngine pushes raw peak values; the smoothing
/// (decay + attack) lives here so the math stays in one place and the
/// HUD just renders.
@MainActor
final class RecordingLevelMeter: ObservableObject {
    static let shared = RecordingLevelMeter()
    private init() {}

    /// 0…1 envelope of the user microphone (AVAudioEngine input tap).
    @Published private(set) var micLevel: Float = 0
    /// 0…1 envelope of the system / loopback audio (SCStream .audio).
    @Published private(set) var systemLevel: Float = 0

    /// Rolling history of combined `max(mic, system)` levels — drives
    /// the waveform-style bars in the floating HUD. Index 0 is newest;
    /// each frame we shift the array one slot to the right.
    @Published private(set) var history: [Float] = Array(repeating: 0, count: barCount)
    static let barCount = 7

    /// Frames since last UI publish — we only push at ~30 Hz to keep
    /// SwiftUI redraws cheap. CaptureEngine taps fire every ~93 ms at
    /// 4096 frames / 44.1 kHz, which is already close to that, but the
    /// guard protects future tap-size changes.
    private var lastPublishMic: CFTimeInterval = 0
    private var lastPublishSys: CFTimeInterval = 0
    private var lastHistoryPush: CFTimeInterval = 0
    private static let publishHz: CFTimeInterval = 1.0 / 30.0
    private static let historyPushHz: CFTimeInterval = 1.0 / 12.0  // 12 fps shift

    func reset() {
        micLevel = 0
        systemLevel = 0
        history = Array(repeating: 0, count: Self.barCount)
        lastPublishMic = 0
        lastPublishSys = 0
        lastHistoryPush = 0
    }

    /// Called from CaptureEngine's mic tap. Always invoked on the audio
    /// thread — we hop to the main actor to mutate `@Published` state.
    nonisolated func ingestMic(buffer: AVAudioPCMBuffer) {
        let peak = Self.peak(of: buffer)
        Task { @MainActor in self.applyMic(peak: peak) }
    }

    /// Called from CaptureEngine's system-audio path. We accept a raw
    /// CMSampleBuffer here since SCStream hands us those, not
    /// AVAudioPCMBuffer.
    nonisolated func ingestSystem(sample: CMSampleBuffer) {
        let peak = Self.peak(of: sample)
        Task { @MainActor in self.applySystem(peak: peak) }
    }

    @MainActor
    private func applyMic(peak: Float) {
        let now = CACurrentMediaTime()
        // perceptual: sqrt makes quiet speech (≈0.05 raw) read as a
        // visible bar (≈0.22 mapped) without hard-clipping loud bursts.
        let mapped = min(1, sqrt(max(0, peak) * 3))
        guard now - lastPublishMic >= Self.publishHz else { return }
        lastPublishMic = now
        micLevel = Self.envelope(current: micLevel, target: mapped)
        pushHistoryIfDue(now: now)
    }

    @MainActor
    private func applySystem(peak: Float) {
        let now = CACurrentMediaTime()
        let mapped = min(1, sqrt(max(0, peak) * 3))
        guard now - lastPublishSys >= Self.publishHz else { return }
        lastPublishSys = now
        systemLevel = Self.envelope(current: systemLevel, target: mapped)
        pushHistoryIfDue(now: now)
    }

    /// Shift the bar history one slot right and write the latest combined
    /// level into the new head. Throttled separately from the per-channel
    /// publish rate so the bars travel at a steady, readable pace
    /// regardless of how fast taps fire.
    @MainActor
    private func pushHistoryIfDue(now: CFTimeInterval) {
        guard now - lastHistoryPush >= Self.historyPushHz else { return }
        lastHistoryPush = now
        var next = history
        let head = max(micLevel, systemLevel)
        if next.count > 1 {
            for i in stride(from: next.count - 1, through: 1, by: -1) {
                next[i] = next[i - 1]
            }
        }
        next[0] = head
        history = next
    }

    /// Fast attack (level snaps up to a louder peak), slow release
    /// (level decays smoothly during silence). Tweaked by feel — too
    /// slow and the bars feel laggy, too fast and they twitch.
    private static func envelope(current: Float, target: Float) -> Float {
        if target > current {
            return current + (target - current) * 0.6   // attack
        } else {
            return current + (target - current) * 0.18  // release
        }
    }

    /// Linear peak over the first channel of an AVAudioPCMBuffer.
    /// Cheap enough to call per-tap — we only walk floatChannelData.
    nonisolated private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var p: Float = 0
        for i in 0..<n {
            let s = data[i]
            let a = s < 0 ? -s : s
            if a > p { p = a }
        }
        return min(1, p)
    }

    /// Linear peak over a CMSampleBuffer's first channel. Decodes the
    /// audio buffer list lazily; we only look at the first packet's
    /// worth of samples since we're after a coarse level, not RMS.
    nonisolated private static func peak(of sample: CMSampleBuffer) -> Float {
        guard CMSampleBufferGetNumSamples(sample) > 0,
              let formatDesc = CMSampleBufferGetFormatDescription(sample),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return 0 }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return 0 }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return 0 }
        // For non-Float32 (system audio is usually Float32 already) we
        // could copy via converter — but skipping the meter for those
        // edge cases is fine, the HUD just stays at zero.
        guard format.commonFormat == .pcmFormatFloat32 else { return 0 }
        return peak(of: pcm)
    }
}
