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
/// 0.7.0). RMS-gating is good enough, Gemini's anti-hallucination
/// clause covers the false-positive case (we ship a sub-second of room
/// tone, model returns no segment).
enum VoiceActivityDetector {

    /// One contiguous chunk of speech on the original timeline. The
    /// `compressedStartMs` field is filled in only after we lay segments
    /// into the speech-only file (`concatenateSpeech`); for raw detector
    /// output it stays at -1, see `Projection` for how the two timelines
    /// relate.
    struct SpeechSegment {
        let startMs: Int64
        let endMs: Int64

        var durationMs: Int64 { endMs - startMs }
    }

    struct Config {
        /// Per-window RMS at or above which a frame is "speech".
        /// 0.005 ≈ -46 dBFS, quiet conversational levels still register;
        /// HVAC hum / room tone at -55 dBFS does not.
        var rmsThreshold: Float = 0.005
        /// Window size for the RMS computation. 30 ms is the WebRTC/Silero
        /// default, short enough to catch glottal onsets, long enough
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

    /// Speech-energy summary used to CHOOSE between the two system
    /// tracks (Core-Audio tap vs ScreenCaptureKit). On a Bluetooth
    /// output route the tap captures a faint, attenuated bleed, not
    /// true silence, so the old "tap definitely silent" gate never
    /// tripped and the good SCK backup was discarded. Comparing voiced
    /// time + mean voiced RMS lets us pick the track that actually has
    /// the remote speech. `nil` on read error; (0, 0) on a silent file.
    static func voicedEnergy(
        audioURL: URL, config: Config = Config()
    ) -> (voicedMs: Int64, meanRMS: Float)? {
        guard let file = try? AVAudioFile(forReading: audioURL) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return (0, 0) }
        let totalFrames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: totalFrames) else { return nil }
        do { try file.read(into: buf, frameCount: totalFrames) } catch { return nil }
        guard let channels = buf.floatChannelData else { return nil }

        let frames = Int(buf.frameLength)
        let channelCount = Int(format.channelCount)
        let windowFrames = max(1, Int(Double(config.windowMs) * sampleRate / 1000.0))
        let hopFrames = max(1, Int(Double(config.hopMs) * sampleRate / 1000.0))

        var voicedWindows = 0
        var voicedRmsSum: Float = 0
        var pos = 0
        while pos + windowFrames <= frames {
            var sumSq: Float = 0
            for ch in 0..<channelCount {
                let data = channels[ch]
                for i in 0..<windowFrames {
                    let s = data[pos + i]
                    sumSq += s * s
                }
            }
            let rms = sqrtf(sumSq / Float(windowFrames * channelCount))
            if rms >= config.rmsThreshold {
                voicedWindows += 1
                voicedRmsSum += rms
            }
            pos += hopFrames
        }
        let voicedMs = Int64(voicedWindows) * Int64(config.hopMs)
        let mean = voicedWindows > 0 ? voicedRmsSum / Float(voicedWindows) : 0
        return (voicedMs, mean)
    }

    /// Per-window RMS series for a whole file (same windowing as
    /// `detect`). Used to compare two tracks instant-by-instant.
    private static func windowRMS(audioURL: URL,
                                  config: Config) -> (values: [Float], totalDurationMs: Int64)? {
        guard let file = try? AVAudioFile(forReading: audioURL) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return ([], 0) }
        let totalFrames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }
        do { try file.read(into: buf, frameCount: totalFrames) } catch { return nil }
        guard let channels = buf.floatChannelData else { return nil }
        let frames = Int(buf.frameLength)
        let channelCount = Int(format.channelCount)
        let windowFrames = max(1, Int(Double(config.windowMs) * sampleRate / 1000.0))
        let hopFrames = max(1, Int(Double(config.hopMs) * sampleRate / 1000.0))
        var out: [Float] = []
        out.reserveCapacity(frames / hopFrames + 1)
        var pos = 0
        while pos + windowFrames <= frames {
            var sumSq: Float = 0
            for ch in 0..<channelCount {
                let data = channels[ch]
                for i in 0..<windowFrames {
                    let s = data[pos + i]
                    sumSq += s * s
                }
            }
            out.append(sqrtf(sumSq / Float(windowFrames * channelCount)))
            pos += hopFrames
        }
        return (out, Int64(Double(frames) / sampleRate * 1000.0))
    }

    /// Where `primary` carries speech AND is the DOMINANT track: its
    /// windowed RMS clears an ADAPTIVE voice floor and exceeds 1.2x the
    /// sibling track's RMS over the same instant.
    ///
    /// Plain `detect()` marks any audible window as speech — on a mic
    /// track that includes the far end's speaker bleed AND the mic's own
    /// noise floor (measured ~-44 dBFS on a real recording, just above
    /// the fixed 0.005 gate), so ~43% of the timeline read as "voiced"
    /// while the user spoke for ~23%. Two changes make the signal
    /// discriminative: (1) the floor adapts to the recording — 0.4x the
    /// 90th-percentile window RMS, never below 0.005 — which sits above
    /// the noise floor but below quiet speech; (2) a window counts only
    /// when primary RMS > 1.2x the sibling's, the same cross-track test
    /// the mis-placement diagnosis used. 300 ms windows at 100 ms steps
    /// integrate over word-level burstiness. Both files are left-padded
    /// to a shared capture clock at write time, so equal indices are the
    /// same instant. `nil` when either file can't be read.
    struct DominanceMap {
        let stepMs: Int64
        /// Per-step "primary is speaking here" flags, step k covers
        /// [k*stepMs, k*stepMs + windowMs).
        let dominant: [Bool]
        /// Collapsed spans: gaps <= 300 ms bridged, runs < 500 ms dropped.
        let spans: [SpeechSegment]

        /// Fraction of the interval's steps that are primary-dominant.
        func fraction(startMs: Int64, endMs: Int64) -> Double {
            let lo = max(0, Int(startMs / stepMs))
            let hi = min(dominant.count, max(lo + 1, Int(endMs / stepMs)))
            guard hi > lo else { return 0 }
            var n = 0
            for k in lo..<hi where dominant[k] { n += 1 }
            return Double(n) / Double(hi - lo)
        }

        /// First/last dominant instant inside the interval, nil when none.
        func dominantEdges(startMs: Int64, endMs: Int64, windowMs: Int64) -> (first: Int64, last: Int64)? {
            let lo = max(0, Int(startMs / stepMs))
            let hi = min(dominant.count, max(lo + 1, Int(endMs / stepMs)))
            guard hi > lo else { return nil }
            var first: Int? = nil
            var last: Int? = nil
            for k in lo..<hi where dominant[k] {
                if first == nil { first = k }
                last = k
            }
            guard let f = first, let l = last else { return nil }
            return (Int64(f) * stepMs, Int64(l) * stepMs + windowMs)
        }
    }

    static let dominanceWindowMs: Int64 = 300

    static func dominanceMap(primaryURL: URL,
                             referenceURL: URL) -> DominanceMap? {
        var cfg = Config()
        cfg.windowMs = Int(dominanceWindowMs)
        cfg.hopMs = 100
        guard let prim = windowRMS(audioURL: primaryURL, config: cfg),
              let ref = windowRMS(audioURL: referenceURL, config: cfg) else { return nil }
        guard !prim.values.isEmpty else {
            return DominanceMap(stepMs: 100, dominant: [], spans: [])
        }
        let sortedVals = prim.values.sorted()
        let p90 = sortedVals[min(sortedVals.count - 1, Int(Double(sortedVals.count) * 0.90))]
        let floor = max(0.005, 0.4 * p90)
        var dom: [Bool] = []
        dom.reserveCapacity(prim.values.count)
        for (i, p) in prim.values.enumerated() {
            let r = i < ref.values.count ? ref.values[i] : 0
            dom.append(p >= floor && p > 1.2 * r)
        }
        let spans = collapse(voiced: dom,
                             hopMs: 100,
                             minSpeechMs: 500,
                             maxGapMs: 300,
                             paddingMs: 0,
                             totalDurationMs: prim.totalDurationMs)
        // collapse() sizes runs by hop count; widen each run's end by the
        // window tail so a span covers the full audible stretch.
        let widened = spans.map {
            SpeechSegment(startMs: $0.startMs,
                          endMs: min(prim.totalDurationMs, $0.endMs + dominanceWindowMs - 100))
        }
        return DominanceMap(stepMs: 100, dominant: dom, spans: widened)
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
        /// A timestamp inside an inserted silence gap (see `concatenateSpeech`
        /// `gapMs`) is snapped by what it marks: a START goes to the next
        /// slot's start (the speech it opens), an END to the previous slot's
        /// end (the speech it closes). Whisper stamps the first word of a
        /// segment at the segment's start, which after concatenation sits in
        /// the gap BEFORE the island; mapping that to the previous island's
        /// end made a far-end utterance appear 18 s early, glued to the tail
        /// of the previous one, and a two-word turn span 20 s of silence.
        func toOriginal(compressedMs: Int64, isEnd: Bool = false) -> Int64 {
            var prev: Slot? = nil
            for slot in slots {
                if compressedMs < slot.compressedEndMs {
                    if compressedMs >= slot.compressedStartMs {
                        return slot.originalStartMs + (compressedMs - slot.compressedStartMs)
                    }
                    // Inside the gap before this slot.
                    if isEnd, let p = prev { return p.originalStartMs + p.durationMs }
                    return slot.originalStartMs
                }
                prev = slot
            }
            // Past the last slot. Gemini's per-chunk timestamps bunch
            // up near the end of a long file and routinely overshoot the
            // final speech slot, so a whole closing exchange lands here.
            // The old code clamped EVERY such turn onto the single
            // instant `lastOriginalStart + duration`, the entire goodbye
            // block collapsed onto one timestamp and clicking any of
            // those lines seeked to the very end of the recording.
            // Continue the last slot's 1:1 mapping instead: the tail
            // turns keep their relative order and spacing and stay
            // individually click-seekable. A small overshoot past the
            // real audio end is harmless, the media element clamps an
            // over-long currentTime to its duration.
            if let last = slots.last {
                return last.originalStartMs + (compressedMs - last.compressedStartMs)
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
    /// `gapMs` inserts that much digital silence BETWEEN consecutive
    /// segments. Butting speech islands hard against each other (the old
    /// behaviour) erases every pause the far end left, and Whisper then
    /// merges several short replies into one run-on segment and garbles
    /// the joins (measured on a real Discord call: 35 s of separate
    /// far-end phrases came back as ONE 122 s "turn" of mush). A short
    /// pause restores the sentence boundaries Whisper segments on. The
    /// projection maps a timestamp inside a gap to the nearer slot edge.
    static func concatenateSpeech(audioURL: URL,
                                  segments: [SpeechSegment],
                                  outURL: URL,
                                  gapMs: Int64 = 0) throws -> Projection {
        let inFile = try AVAudioFile(forReading: audioURL)
        let format = inFile.processingFormat
        let sampleRate = format.sampleRate

        let outFile = try AVAudioFile(forWriting: outURL,
                                      settings: format.settings,
                                      commonFormat: format.commonFormat,
                                      interleaved: format.isInterleaved)

        var slots: [Projection.Slot] = []
        var compressedCursorMs: Int64 = 0
        let gapFrames = AVAudioFrameCount(max(0, Double(gapMs) / 1000.0 * sampleRate))
        let gapBuf: AVAudioPCMBuffer? = gapFrames > 0
            ? AVAudioPCMBuffer(pcmFormat: format, frameCapacity: gapFrames) : nil
        if let g = gapBuf {
            g.frameLength = gapFrames
            // Explicit zero fill: buffer memory is not guaranteed cleared.
            let abl = UnsafeMutableAudioBufferListPointer(g.mutableAudioBufferList)
            for b in abl { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
        }

        for seg in segments {
            let startFrame = AVAudioFramePosition(Double(seg.startMs) / 1000.0 * sampleRate)
            let endFrame = AVAudioFramePosition(Double(seg.endMs) / 1000.0 * sampleRate)
            let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
            guard frameCount > 0 else { continue }
            inFile.framePosition = startFrame
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { continue }
            try inFile.read(into: buf, frameCount: frameCount)
            if let gap = gapBuf, !slots.isEmpty {
                try outFile.write(from: gap)
                compressedCursorMs += Int64(Double(gap.frameLength) / sampleRate * 1000.0)
            }
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
    /// whether the savings are worth the extra disk I/O, for a file
    /// where speech ≈ duration, the concat is a no-op and we just
    /// pass the original through.
    static func totalSpeechMs(_ segments: [SpeechSegment]) -> Int64 {
        segments.reduce(0) { $0 + $1.durationMs }
    }
}
