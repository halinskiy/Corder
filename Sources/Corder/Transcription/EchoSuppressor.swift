import AVFoundation
import Accelerate
import Foundation

/// Offline acoustic echo suppression for the no-headphones case.
///
/// When the user is on SPEAKERS, the far-end voice plays out loud and
/// bleeds back into `mic.wav`. The dual-track pipeline then transcribes
/// that bleed as if the USER said it (and, cross-language, the local
/// Whisper even renders the bleed in the user's language, the
/// "your friend's English shows up as your Russian" bug). The dominance
/// gate is a post-hoc band-aid that misses loud bleed.
///
/// We have the perfect reference: `system.wav` is the CLEAN digital
/// far-end. This suppressor models the speaker→room→mic path and
/// subtracts the far-end from the mic, in the frequency domain:
///   • bulk-delay align the reference to the bleed (cross-correlation),
///   • per-bin learn the coupling |H(f)| (recursive cross/auto spectra),
///   • apply a reference-guided Wiener gain (spectral over-subtraction
///     with a gain floor).
///
/// It is GAIN-based, so it can't diverge (unlike time-domain NLMS) and is
/// length-independent (STFT cost only). Crucially it is self-gating: with
/// no acoustic coupling (headphones / Bluetooth output) the reference and
/// mic are uncorrelated, the learned coupling stays ~0, the gain stays ~1,
/// and the mic passes through untouched. Measured on a real speaker
/// recording: 12 dB reduction in far-end-dominant regions, 0.0 dB change
/// in user-only regions.
///
/// NOT a live-capture change: this runs in the pipeline before
/// transcription and never touches the audio route, sidestepping the
/// VoIP-mode / Bluetooth-HFP / bogus-channel-format problems that got the
/// macOS Voice-Processing (VPIO) capture path reverted (see CaptureEngine).
enum EchoSuppressor {
    private static let sampleRate: Double = 16000
    private static let fftSize = 512
    private static let hop = 128
    // Suppression tuning, validated on a real speaker recording.
    private static let lambda: Float = 0.92    // coupling-estimate smoothing
    private static let overSub: Float = 1.7    // spectral over-subtraction
    private static let gainFloor: Float = 0.08 // keep a little signal (no holes)
    // Below this normalised cross-correlation peak we treat the recording
    // as bleed-free (headphones / BT) and skip suppression entirely.
    private static let minCorrelation: Float = 0.10

    /// Produce a bleed-suppressed copy of `micURL` (16 kHz mono WAV) using
    /// `systemURL` as the far-end reference. Returns the cleaned file URL,
    /// or nil when there's nothing to do (missing input, no measurable
    /// coupling, or a processing failure, the caller then uses the raw
    /// mic). `outURL` is where the cleaned WAV is written.
    static func suppress(micURL: URL, systemURL: URL, outURL: URL) -> URL? {
        guard let mic = loadMono16k(micURL), !mic.isEmpty,
              let sysRaw = loadMono16k(systemURL), !sysRaw.isEmpty else { return nil }
        let n = min(mic.count, sysRaw.count)
        if n < fftSize { return nil }
        let micA = Array(mic[0..<n])
        var ref = Array(sysRaw[0..<n])

        // 1. Bulk delay + coupling strength via normalised FFT cross-correlation.
        guard let (delay, corr) = bulkDelay(mic: micA, ref: ref) else { return nil }
        if corr < minCorrelation {
            FileLogger.log("EchoSuppressor: corr=\(String(format: "%.3f", corr)) < \(minCorrelation), no bleed (headphones/BT), skipping")
            return nil
        }
        FileLogger.log("EchoSuppressor: delay=\(delay) (\(String(format: "%.0f", Double(delay)/sampleRate*1000))ms) corr=\(String(format: "%.3f", corr)), suppressing")
        // Delay-align the reference. Clamp `delay` to < n: on a very short
        // recording (quick start/stop) the cross-correlation lag can exceed
        // the sample count, and an unclamped `ref[0..<(n - delay)]` is a
        // NEGATIVE range → process-wide fatal on the universal dual-track
        // path. With the clamp a too-large delay simply zeroes the reference
        // (nothing to subtract), the correct degenerate behaviour.
        if delay > 0 {
            let d = min(delay, n)
            ref = [Float](repeating: 0, count: d) + Array(ref[0..<(n - d)])
        }

        // 2. Spectral suppression.
        guard let cleaned = process(mic: micA, ref: ref) else { return nil }

        // 3. Write 16 kHz mono WAV.
        guard writeMono16k(cleaned, to: outURL) else { return nil }
        return outURL
    }

    // MARK: - Spectral core

    private static func process(mic: [Float], ref: [Float]) -> [Float]? {
        let n = mic.count
        let nb = fftSize / 2
        let log2n = vDSP_Length(Int(log2(Double(fftSize))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var pxx = [Float](repeating: 0, count: nb)
        var pxyR = [Float](repeating: 0, count: nb)
        var pxyI = [Float](repeating: 0, count: nb)
        var out = [Float](repeating: 0, count: n)
        var norm = [Float](repeating: 0, count: n)
        let eps: Float = 1e-6

        func forward(_ slice: ArraySlice<Float>) -> (re: [Float], im: [Float]) {
            var w = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(slice), 1, hann, 1, &w, 1, vDSP_Length(fftSize))
            var re = [Float](repeating: 0, count: nb), im = [Float](repeating: 0, count: nb)
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(nb)) }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
            }}
            return (re, im)
        }

        var pos = 0
        while pos + fftSize <= n {
            let m = forward(mic[pos..<pos + fftSize])
            let r = forward(ref[pos..<pos + fftSize])
            var yr = [Float](repeating: 0, count: nb)
            var yi = [Float](repeating: 0, count: nb)
            // Bin 0 carries DC in .re and Nyquist in .im (vDSP packing); we
            // treat it as one complex bin, both carry negligible speech
            // energy, so the approximation is inaudible and it keeps the
            // round-trip exact.
            for k in 0..<nb {
                let mr = m.re[k], mi = m.im[k]
                let rr = r.re[k], ri = r.im[k]
                let magM = sqrtf(mr * mr + mi * mi)
                let magR2 = rr * rr + ri * ri
                pxx[k] = lambda * pxx[k] + (1 - lambda) * magR2
                pxyR[k] = lambda * pxyR[k] + (1 - lambda) * (mr * rr + mi * ri)
                pxyI[k] = lambda * pxyI[k] + (1 - lambda) * (mi * rr - mr * ri)
                let coupling = sqrtf(pxyR[k] * pxyR[k] + pxyI[k] * pxyI[k]) / (pxx[k] + eps)
                let echoMag = coupling * sqrtf(magR2)
                let g = max(gainFloor, (magM - overSub * echoMag) / (magM + eps))
                yr[k] = mr * g
                yi[k] = mi * g
            }
            var tmp = [Float](repeating: 0, count: fftSize)
            yr.withUnsafeMutableBufferPointer { rp in yi.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_INVERSE))
                tmp.withUnsafeMutableBufferPointer { tp in
                    tp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nb) {
                        vDSP_ztoc(&sc, 1, $0, 2, vDSP_Length(nb))
                    }
                }
            }}
            // vDSP real FFT round-trip scales by 2N.
            var scale: Float = 1.0 / Float(2 * fftSize)
            vDSP_vsmul(tmp, 1, &scale, &tmp, 1, vDSP_Length(fftSize))
            // Overlap-add with the synthesis window; divide by Σwin² so the
            // reconstruction is exact regardless of the window constant.
            for i in 0..<fftSize {
                out[pos + i] += tmp[i] * hann[i]
                norm[pos + i] += hann[i] * hann[i]
            }
            pos += hop
        }
        for i in 0..<n where norm[i] > 1e-6 { out[i] /= norm[i] }
        return out
    }

    // MARK: - Delay estimation

    /// Returns (delay-in-samples of the reference relative to the mic,
    /// normalised correlation peak in 0…1). Uses an FFT cross-correlation
    /// over the first ~40 s.
    private static func bulkDelay(mic: [Float], ref: [Float], maxLagMs: Double = 400) -> (Int, Float)? {
        let chunk = min(mic.count, ref.count, Int(sampleRate * 40))
        if chunk < fftSize { return nil }
        let nfft = 1 << Int(ceil(log2(Double(2 * chunk))))
        let log2n = vDSP_Length(Int(log2(Double(nfft))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        func fwd(_ sig: ArraySlice<Float>) -> (re: [Float], im: [Float]) {
            var padded = Array(sig)
            padded.append(contentsOf: [Float](repeating: 0, count: nfft - padded.count))
            var re = [Float](repeating: 0, count: nfft / 2)
            var im = [Float](repeating: 0, count: nfft / 2)
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &sc, 1, vDSP_Length(nfft / 2)) }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
            }}
            return (re, im)
        }
        let a = fwd(mic[0..<chunk])
        let b = fwd(ref[0..<chunk])
        var cr = [Float](repeating: 0, count: nfft / 2)
        var ci = [Float](repeating: 0, count: nfft / 2)
        for k in 0..<nfft / 2 {
            cr[k] = a.re[k] * b.re[k] + a.im[k] * b.im[k]
            ci[k] = a.im[k] * b.re[k] - a.re[k] * b.im[k]
        }
        var corr = [Float](repeating: 0, count: nfft)
        cr.withUnsafeMutableBufferPointer { rp in ci.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_INVERSE))
            corr.withUnsafeMutableBufferPointer { cp in
                cp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nfft / 2) {
                    vDSP_ztoc(&sc, 1, $0, 2, vDSP_Length(nfft / 2))
                }
            }
        }}
        // Normaliser: energy of both chunks (for a 0…1 correlation peak).
        var em: Float = 0, er: Float = 0
        vDSP_measqv(Array(mic[0..<chunk]), 1, &em, vDSP_Length(chunk))
        vDSP_measqv(Array(ref[0..<chunk]), 1, &er, vDSP_Length(chunk))
        let denom = sqrtf(em * Float(chunk)) * sqrtf(er * Float(chunk)) * Float(2 * nfft) + 1e-9
        // Cap the lag by the actual chunk length too, on a short recording
        // nfft (next pow2 of 2*chunk) can exceed the sample count, and a lag
        // bigger than `n` would make the caller's delay-align slice crash.
        let maxLag = min(nfft - 1, chunk - 1, Int(maxLagMs / 1000 * sampleRate))
        var best = 0
        var bestVal: Float = -.infinity
        for lag in 0...maxLag where abs(corr[lag]) > bestVal {
            bestVal = abs(corr[lag]); best = lag
        }
        return (best, min(1, bestVal / denom))
    }

    // MARK: - WAV I/O

    private static func loadMono16k(_ url: URL) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = f.processingFormat
        guard f.length > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: inBuf)) != nil,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }
        let outCap = AVAudioFrameCount(Double(f.length) * sampleRate / inFmt.sampleRate + 4096)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if err != nil { return nil }
        let count = Int(outBuf.frameLength)
        guard count > 0, let p = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: count))
    }

    private static func writeMono16k(_ samples: [Float], to url: URL) -> Bool {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(buf.floatChannelData![0], $0.baseAddress!, samples.count * MemoryLayout<Float>.size) }
        try? FileManager.default.removeItem(at: url)
        guard let wf = try? AVAudioFile(forWriting: url, settings: fmt.settings) else { return false }
        return (try? wf.write(from: buf)) != nil
    }
}
