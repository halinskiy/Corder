import Foundation
import AVFoundation
import Accelerate
import Combine
import os

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

    /// REAL frequency spectrum (FFT) of the live audio — one value per
    /// log-spaced band, 0…1, fast-attack/slow-release enveloped. This is
    /// what drives the floating-HUD equalizer: each bar is a genuine
    /// frequency band (low → high), so lows / mids / highs react
    /// independently to the actual sound, not a single level faked across
    /// bars. Fed by BOTH mic and system buffers (louder band wins).
    static let spectrumBands = 11
    @Published private(set) var spectrum: [Float] = Array(repeating: 0, count: spectrumBands)
    // Per-SOURCE envelopes + AGC references. The system tap fires ~86 Hz
    // (512-frame buffers) while the mic fires ~10 Hz (4096), so if both fed
    // ONE envelope the frequent (usually silent) system buffers would decay
    // the bars to flat faster than the mic could raise them — the "barely
    // reacts" bug. Keeping them separate and publishing the per-band MAX
    // means a silent system track can't wash out the user's voice.
    private var micEnv = [Float](repeating: 0, count: spectrumBands)
    private var sysEnv = [Float](repeating: 0, count: spectrumBands)
    private var micRef = [Float](repeating: 0.03, count: spectrumBands)
    private var sysRef = [Float](repeating: 0.03, count: spectrumBands)
    private var lastSpecPublish: CFTimeInterval = 0
    enum SpecSource { case mic, system }

    // FFT scratch — created once. vDSP FFT setups are read-only during a
    // transform, so the two capture threads (mic + system) can share this.
    private static let fftSize = 1024
    private static let fftLog2n = vDSP_Length(10)
    private static let fftSetup: FFTSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))!
    private static let hannWindow: [Float] = {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return w
    }()

    /// Frames since last UI publish. Gated at the HUD's render rate (20 Hz)
    /// so we never publish a spectrum the HUD can't draw — publishing at 30
    /// against a 20 fps consumer made a 3:2 beat where every third update was
    /// dropped unevenly. (The mic tap fires at only ~10 Hz — 4096 frames /
    /// 44.1 kHz — so the visual smoothness comes from the HUD's per-frame
    /// lerp, not this gate; the gate just bounds redraw cost.)
    private var lastPublishMic: CFTimeInterval = 0
    private var lastPublishSys: CFTimeInterval = 0
    private var lastHistoryPush: CFTimeInterval = 0
    private static let publishHz: CFTimeInterval = 1.0 / 20.0
    private static let historyPushHz: CFTimeInterval = 1.0 / 12.0  // 12 fps shift

    /// Loudest raw peak seen this recording session (pre-throttle, so the
    /// 30 Hz publish gate can't hide a brief signal). Used post-stop to
    /// tell the user immediately if the track is effectively silent.
    private(set) var sessionMaxMic: Float = 0
    private(set) var sessionMaxSystem: Float = 0
    /// True when neither track ever rose above a near-silence floor
    /// (≈ -48 dBFS) — i.e. nothing was actually captured.
    var capturedSilence: Bool { max(sessionMaxMic, sessionMaxSystem) < 0.004 }

    /// Timestamp of the most recent audible buffer (peak ≥ speech floor).
    /// The popover reads this and the current wall clock to decide
    /// whether to surface the "no one's spoken for 10 minutes" warning
    /// while a recording is in progress. `nil` means we haven't crossed
    /// the floor yet this session.
    @Published private(set) var lastSpeechAt: Date? = nil
    /// Threshold above which we consider a buffer to contain real
    /// speech (or any meaningful audio activity). Sits well above the
    /// silence floor (0.004) used for the post-stop "no audio" check
    /// but below normal-volume voice — keyboard taps and HVAC won't
    /// reset the warning, but quiet talking will.
    private static let speechFloor: Float = 0.05

    func reset() {
        micLevel = 0
        systemLevel = 0
        spectrum = Array(repeating: 0, count: Self.spectrumBands)
        micEnv = Array(repeating: 0, count: Self.spectrumBands)
        sysEnv = Array(repeating: 0, count: Self.spectrumBands)
        micRef = Array(repeating: 0.03, count: Self.spectrumBands)
        sysRef = Array(repeating: 0.03, count: Self.spectrumBands)
        history = Array(repeating: 0, count: Self.barCount)
        lastPublishMic = 0
        lastPublishSys = 0
        lastHistoryPush = 0
        sessionMaxMic = 0
        sessionMaxSystem = 0
        lastSpeechAt = nil
    }

    // Rate gates that bound how often the FFT + MainActor hop run, on the
    // AUDIO thread, INDEPENDENT of how fast the taps fire. The input sample
    // rate varies (16 kHz or 44.1 kHz) and the buffer size is small for a
    // responsive equalizer, so the tap can fire 40-90 Hz — doing a full FFT
    // and spawning a @MainActor Task every time was a real recording-load
    // spike. We process at ~25 Hz (mic) / 30 Hz (system), which is already
    // above what the 20 fps HUD (with its per-frame lerp) can show, so the
    // animation is unaffected while the load drops back down. File writes are
    // NOT gated here — they happen per buffer in CaptureEngine.
    private let micGate = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private let sysGate = OSAllocatedUnfairLock(initialState: CFTimeInterval(0))
    private static let micIngestInterval: CFTimeInterval = 1.0 / 25.0
    private static let sysIngestInterval: CFTimeInterval = 1.0 / 30.0

    private nonisolated func passGate(_ gate: OSAllocatedUnfairLock<CFTimeInterval>,
                                      _ interval: CFTimeInterval) -> Bool {
        let now = CACurrentMediaTime()
        return gate.withLock { last in
            if now - last >= interval { last = now; return true }
            return false
        }
    }

    /// Called from CaptureEngine's mic tap. Always invoked on the audio
    /// thread — we hop to the main actor to mutate `@Published` state.
    nonisolated func ingestMic(buffer: AVAudioPCMBuffer) {
        guard passGate(micGate, Self.micIngestInterval) else { return }
        let peak = Self.peak(of: buffer)
        let spec = Self.spectrum(of: buffer)
        Task { @MainActor in
            self.applyMic(peak: peak)
            self.applySpectrum(spec, source: .mic)
        }
    }

    /// System audio now arrives as AVAudioPCMBuffer from the Core Audio
    /// process tap (not SCStream's CMSampleBuffer). Same envelope path.
    nonisolated func ingestSystem(pcm: AVAudioPCMBuffer) {
        guard passGate(sysGate, Self.sysIngestInterval) else { return }
        let peak = Self.peak(of: pcm)
        let spec = Self.spectrum(of: pcm)
        Task { @MainActor in
            self.applySystem(peak: peak)
            self.applySpectrum(spec, source: .system)
        }
    }

    @MainActor
    private func applyMic(peak: Float) {
        if peak > sessionMaxMic { sessionMaxMic = peak }
        if peak >= Self.speechFloor { lastSpeechAt = Date() }
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
        if peak > sessionMaxSystem { sessionMaxSystem = peak }
        if peak >= Self.speechFloor { lastSpeechAt = Date() }
        let now = CACurrentMediaTime()
        let mapped = min(1, sqrt(max(0, peak) * 3))
        guard now - lastPublishSys >= Self.publishHz else { return }
        lastPublishSys = now
        systemLevel = Self.envelope(current: systemLevel, target: mapped)
        pushHistoryIfDue(now: now)
    }

    /// Fold a buffer's RAW band amplitudes into the published bands with
    /// per-band AGC. The mic level varies wildly by setup (a quiet AirPods
    /// mic vs a loud video on system audio span ~10×), so a fixed gain
    /// either pins everything to the ceiling or leaves quiet speech as flat
    /// dots. Instead each band normalises against its OWN slow-decaying
    /// reference peak — so quiet speech and loud audio BOTH fill the bars
    /// and show real spectral shape. Verified on real quiet + normal mic
    /// recordings. `amps == all-zero` means the stateless gate found
    /// silence → bars ease to flat. Then a fast-attack / slow-release
    /// envelope, published at the 30 Hz gate.
    @MainActor
    private func applySpectrum(_ amps: [Float], source: SpecSource) {
        let bands = Self.spectrumBands
        let silent = !amps.contains { $0 > 0 }
        // The envelope's release runs per-CALL, but the two sources fire at
        // very different rates (system ~86 Hz, mic ~10 Hz). Scale the release
        // by the source rate so a fast source doesn't decay faster in real
        // time than a slow one — otherwise the bars still favour whichever
        // source ticks more often.
        // Mic release lowered 0.22 → 0.12: the mic now fires ~15.6 Hz (1024
        // frames) instead of ~10 Hz, and a gentler release holds the bars
        // fuller between syllables so the equalizer reads as alive, not
        // flickering down to flat. Mic AGC floor lowered 0.03 → 0.02 so a
        // quiet / partly-muted mic still drives the bars up to a visible
        // level (the user couldn't tell it was working otherwise).
        let release: Float = source == .system ? 0.04 : 0.12
        for b in 0..<bands {
            if source == .mic {
                micRef[b] = max(amps[b], micRef[b] * 0.985)
                let disp: Float = silent ? 0 : min(1, amps[b] / max(micRef[b], 0.02))
                micEnv[b] += (disp - micEnv[b]) * (disp > micEnv[b] ? 0.6 : release)
            } else {
                sysRef[b] = max(amps[b], sysRef[b] * 0.985)
                let disp: Float = silent ? 0 : min(1, amps[b] / max(sysRef[b], 0.03))
                sysEnv[b] += (disp - sysEnv[b]) * (disp > sysEnv[b] ? 0.6 : release)
            }
        }
        let now = CACurrentMediaTime()
        guard now - lastSpecPublish >= Self.publishHz else { return }
        lastSpecPublish = now
        // Per-band max of the two sources — the louder of mic / system wins,
        // and a silent track contributes 0 instead of dragging the bars down.
        spectrum = (0..<bands).map { max(micEnv[$0], sysEnv[$0]) }
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

    /// Real FFT spectrum of a buffer → `spectrumBands` log-spaced bands,
    /// each 0…1. A frequency tilt (low gain → high gain) compensates for
    /// speech being bass-heavy, so the high bands are visibly active too.
    /// Validated offline on a real recording: lows / mids / highs move
    /// independently with the actual sound content.
    nonisolated private static func spectrum(of buffer: AVAudioPCMBuffer) -> [Float] {
        let bands = spectrumBands
        guard let data = buffer.floatChannelData?[0] else { return [Float](repeating: 0, count: bands) }
        let avail = Int(buffer.frameLength)
        guard avail >= 64 else { return [Float](repeating: 0, count: bands) }
        let n = min(avail, fftSize)
        // Noise gate: near-silence FFTs to a low jittery floor across all
        // bands (looks like the bars "twitching" at rest). Below a small
        // peak, return a clean flat zero instead.
        var bufPeak: Float = 0
        vDSP_maxmgv(data, 1, &bufPeak, vDSP_Length(n))
        if bufPeak < 0.004 { return [Float](repeating: 0, count: bands) }
        var samples = [Float](repeating: 0, count: fftSize)   // zero-padded
        for i in 0..<n { samples[i] = data[i] }
        vDSP_vmul(samples, 1, hannWindow, 1, &samples, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { rp in imagp.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            samples.withUnsafeBytes {
                vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(half))
            }
            vDSP_fft_zrip(fftSetup, &sc, 1, fftLog2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&sc, 1, &mags, 1, vDSP_Length(half))   // magnitude²
        }}

        var out = [Float](repeating: 0, count: bands)
        let minBin = 1, maxBin = half - 1
        let ratio = Double(maxBin) / Double(minBin)
        for b in 0..<bands {
            let lo = Int(Double(minBin) * pow(ratio, Double(b) / Double(bands)))
            let hi = Int(Double(minBin) * pow(ratio, Double(b + 1) / Double(bands)))
            let lo2 = max(minBin, lo), hi2 = max(lo2 + 1, min(maxBin, hi))
            var sum: Float = 0
            for k in lo2..<hi2 { sum += mags[k] }
            // RAW band amplitude. Normalisation is per-band AGC in
            // `applySpectrum` (it needs state), so this stays stateless.
            out[b] = sqrtf(sum / Float(hi2 - lo2))
        }
        return out
    }

}
