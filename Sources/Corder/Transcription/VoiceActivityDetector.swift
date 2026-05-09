import Foundation
import AVFoundation

/// Local voice-activity detector built on a sliding-window RMS gate.
///
/// We use it to compress mic.wav / system.wav to "speech-only" before
/// shipping them to Gemini. Long silent stretches at the edges of a
/// recording (mic warming up, you're listening to the other side, the
/// pause after Stop is pressed) and inside it (you're muted while a
/// teammate talks for two minutes) become Gemini tokens we pay for
/// without getting back any segments. With a pre-pass that drops them
/// before upload, we shave 10–20 % off the API bill on talk-heavy mic
/// tracks and ~5–10 % on system tracks where music / video plays
/// continuously.
///
/// The detector is deliberately simple: one float threshold + min-speech
/// + max-gap. ML-based VAD (Silero, WebRTC) would be more accurate on
/// borderline frames, but pulling a CoreML model in for a problem this
/// small is the kind of bloat we just retired (see WhisperKit removal in
/// 0.7.0). RMS-gating is good enough — Gemini's anti-hallucination
/// clause covers the false-positive case (we ship a sub-second of room
/// tone, model returns no segment).
enum VoiceActivityDetector {

    /// One contiguous chunk of speech on the original timeline. The
    /// `compressedStartMs` field is filled in only after we lay segments
    /// into the speech-only file (`concatenateSpeech`); for raw detector
    /// output it stays at -1 — see `Projection` for how the two timelines
    /// relate.
    struct SpeechSegment {
        let startMs: Int64
        let endMs: Int64

        var durationMs: Int64 { endMs - startMs }
    }

    struct Config {
        /// Per-window RMS at or above which a frame is "speech".
        /// 0.005 ≈ -46 dBFS — quiet conversational levels still register;
        /// HVAC hum / room tone at -55 dBFS does not.
        var rmsThreshold: Float = 0.005
        /// Window size for the RMS computation. 30 ms is the WebRTC/Silero
        /// default — short enough to catch glottal onsets, long enough
        /// that one click doesn't flip the gate.
        var windowMs: Int = 30
        /// Hop size. 10 ms gives 3× overlap; smoother gate transitions.
        var hopMs: Int = 10
        /// Drop speech segments shorter than this. A 200 ms blip is
        /// almost always a chair creak / mouse click rather than a word.
        var minSpeechMs: Int64 = 200
        /// Bridge silences shorter than this. Speakers pause between
        /// words / for breath; cutting at the first sub-RMS frame would
        /// shred a sentence into a hundred segments. 600 ms keeps
        /// natural prosody intact.
        var maxGapMs: Int64 = 600
        /// Pad each segment edge by this much before extraction, so we
        /// don't clip a soft consonant onset / decaying vowel tail.
        var paddingMs: Int64 = 200
    }

    /// Run the detector over a wav file. Returns `nil` on read errors so
    /// the caller can fall back to "transcribe the whole file" instead of
    /// failing the meeting; an empty array means "we read it fine, the
    /// file is silent" (caller should skip the Gemini call).
    static func detect(audioURL: URL, config: Config = Config()) -> [SpeechSegment]? {
        guard let file = try? AVAudioFile(forReading: audioURL) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return [] }

        let totalFrames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }
        do {
            try file.read(into: buf, frameCount: totalFrames)
        } catch {
            return nil
        }
        guard let channels = buf.floatChannelData else { return nil }

        let frames = Int(buf.frameLength)
        let channelCount = Int(format.channelCount)
        let windowFrames = max(1, Int(Double(config.windowMs) * sampleRate / 1000.0))
        let hopFrames = max(1, Int(Double(config.hopMs) * sampleRate / 1000.0))

        // Per-window RMS. We mark each window as voiced/silent against
        // the threshold, then collapse into [SpeechSegment] in a second
        // pass that handles min-speech / max-gap.
        var voiced: [Bool] = []
        voiced.reserveCapacity(frames / hopFrames + 1)

        var pos = 0
        while pos + windowFrames <= frames {
            var sumSq: Float = 0
            // Mix channels into a single RMS by averaging |sample| across
            // channels at each frame. Cheaper than computing per-channel
            // RMS and taking the max; results in practice are equivalent
            // for our inputs (mic = mono, system = stereo with near-
            // identical content).
            for ch in 0..<channelCount {
                let data = channels[ch]
                for i in 0..<windowFrames {
                    let s = data[pos + i]
                    sumSq += s * s
                }
            }
            let rms = sqrtf(sumSq / Float(windowFrames * channelCount))
            voiced.append(rms >= config.rmsThreshold)
            pos += hopFrames
        }

        return collapse(voiced: voiced,
                        hopMs: Int64(config.hopMs),
                        minSpeechMs: config.minSpeechMs,
                        maxGapMs: config.maxGapMs,
                        paddingMs: config.paddingMs,
                        totalDurationMs: Int64(Double(frames) / sampleRate * 1000.0))
    }

    /// Take the voiced/silent bitmap and produce final [SpeechSegment].
    ///
    /// 1. Run-length encode into raw speech runs.
    /// 2. Bridge silences shorter than `maxGapMs` (merge adjacent runs).
    /// 3. Drop runs shorter than `minSpeechMs`.
    /// 4. Pad edges by `paddingMs`, clamp to [0, totalDurationMs].
    private static func collapse(voiced: [Bool],
                                 hopMs: Int64,
                                 minSpeechMs: Int64,
                                 maxGapMs: Int64,
                                 paddingMs: Int64,
                                 totalDurationMs: Int64) -> [SpeechSegment] {
        guard !voiced.isEmpty else { return [] }

        // Step 1: raw runs.
        var runs: [(start: Int64, end: Int64)] = []
        var i = 0
        while i < voiced.count {
            if voiced[i] {
                var j = i
                while j < voiced.count, voiced[j] { j += 1 }
                runs.append((Int64(i) * hopMs, Int64(j) * hopMs))
                i = j
            } else {
                i += 1
            }
        }
        guard !runs.isEmpty else { return [] }

        // Step 2: bridge short gaps.
        var merged: [(Int64, Int64)] = [runs[0]]
        for r in runs.dropFirst() {
            let lastEnd = merged.last!.1
            if r.start - lastEnd <= maxGapMs {
                merged[merged.count - 1].1 = r.end
            } else {
                merged.append(r)
            }
        }

        // Step 3 + 4: filter short, pad edges.
        var out: [SpeechSegment] = []
        for r in merged where (r.1 - r.0) >= minSpeechMs {
            let s = max(0, r.0 - paddingMs)
            let e = min(totalDurationMs, r.1 + paddingMs)
            // After padding, two segments may overlap (their padded
            // halves meet); merge into the previous if so.
            if let last = out.last, s <= last.endMs {
                out[out.count - 1] = SpeechSegment(startMs: last.startMs, endMs: max(last.endMs, e))
            } else {
                out.append(SpeechSegment(startMs: s, endMs: e))
            }
        }
        return out
    }

    /// Map from compressed (speech-only) timeline → original timeline.
    /// Built once after concatenation and reused for every Gemini turn.
    struct Projection {
        struct Slot {
            let originalStartMs: Int64
            let compressedStartMs: Int64
            let durationMs: Int64
            var compressedEndMs: Int64 { compressedStartMs + durationMs }
        }

        let slots: [Slot]

        /// Translate a compressed timestamp back onto the original timeline.
        /// If the timestamp falls in a gap (Gemini interpolated past the
        /// end of one slot — rare), we snap to the start of the nearest
        /// following slot rather than refusing the turn.
        func toOriginal(compressedMs: Int64) -> Int64 {
            for slot in slots where compressedMs < slot.compressedEndMs {
                if compressedMs >= slot.compressedStartMs {
                    return slot.originalStartMs + (compressedMs - slot.compressedStartMs)
                }
                return slot.originalStartMs
            }
            // Past the last slot — clamp to its original end.
            if let last = slots.last {
                return last.originalStartMs + last.durationMs
            }
            return compressedMs
        }
    }

    /// Concatenate speech segments into a single new wav at `outURL`.
    /// Returns the projection table needed to map Gemini turns back onto
    /// the original timeline.
    ///
    /// We deliberately preserve the input format (sample rate, channel
    /// count, common format) so the existing upload + chunk paths in
    /// GeminiTranscriber don't have to special-case anything.
    static func concatenateSpeech(audioURL: URL,
                                  segments: [SpeechSegment],
                                  outURL: URL) throws -> Projection {
        let inFile = try AVAudioFile(forReading: audioURL)
        let format = inFile.processingFormat
        let sampleRate = format.sampleRate

        let outFile = try AVAudioFile(forWriting: outURL,
                                      settings: format.settings,
                                      commonFormat: format.commonFormat,
                                      interleaved: format.isInterleaved)

        var slots: [Projection.Slot] = []
        var compressedCursorMs: Int64 = 0

        for seg in segments {
            let startFrame = AVAudioFramePosition(Double(seg.startMs) / 1000.0 * sampleRate)
            let endFrame = AVAudioFramePosition(Double(seg.endMs) / 1000.0 * sampleRate)
            let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
            guard frameCount > 0 else { continue }
            inFile.framePosition = startFrame
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { continue }
            try inFile.read(into: buf, frameCount: frameCount)
            try outFile.write(from: buf)

            let actualMs = Int64(Double(buf.frameLength) / sampleRate * 1000.0)
            slots.append(.init(originalStartMs: seg.startMs,
                               compressedStartMs: compressedCursorMs,
                               durationMs: actualMs))
            compressedCursorMs += actualMs
        }
        return Projection(slots: slots)
    }

    /// Sum of all speech segments in ms. Used by the caller to decide
    /// whether the savings are worth the extra disk I/O — for a file
    /// where speech ≈ duration, the concat is a no-op and we just
    /// pass the original through.
    static func totalSpeechMs(_ segments: [SpeechSegment]) -> Int64 {
        segments.reduce(0) { $0 + $1.durationMs }
    }
}
