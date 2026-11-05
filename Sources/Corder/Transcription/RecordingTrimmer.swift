import AVFoundation
import Foundation

/// Cuts a recording down to one time range, in place, so only that part is
/// transcribed and kept. Used on an un-transcribed session (the recording ran
/// for hours after the meeting ended): the user picks the range on the player
/// timeline and everything outside it is deleted from disk.
///
/// Every track is cut by the same range, so mic / system / video stay aligned
/// (they all start at the same capture instant).
enum RecordingTrimmer {
    enum TrimError: Error { case badRange, noAudio }

    static let audioFiles = ["mic.wav", "system.wav", "system_sck.wav", "audio.wav"]

    /// Trims every track in `dir` to `[startSec, endSec)`. Returns the new
    /// duration in ms (from mic.wav, the master track).
    static func trim(dir: URL, startSec: Double, endSec: Double) async throws -> Int64 {
        guard startSec >= 0, endSec > startSec else { throw TrimError.badRange }
        let fm = FileManager.default
        var newDurationMs: Int64?
        for name in audioFiles {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let ms = try trimAudio(url: url, startSec: startSec, endSec: endSec)
            if name == "mic.wav" || newDurationMs == nil { newDurationMs = ms }
            FileLogger.log("RecordingTrimmer: \(name) → \(ms) ms")
        }
        guard let duration = newDurationMs else { throw TrimError.noAudio }
        let video = dir.appendingPathComponent("video.mov")
        if fm.fileExists(atPath: video.path) {
            do { try await trimVideo(url: video, startSec: startSec, endSec: endSec) }
            catch { FileLogger.log("RecordingTrimmer: video trim failed (\(error)), keeping the audio cut") }
        }
        return duration
    }

    /// Copies the frames in range into a temp file next to the source, then
    /// swaps it in. The source is only replaced after a complete write.
    private static func trimAudio(url: URL, startSec: Double, endSec: Double) throws -> Int64 {
        let src = try AVAudioFile(forReading: url)
        let rate = src.processingFormat.sampleRate
        let total = src.length
        let start = min(total, AVAudioFramePosition(startSec * rate))
        let end = min(total, AVAudioFramePosition(endSec * rate))
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".trim-" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        do {
            let dst = try AVAudioFile(
                forWriting: tmp,
                settings: src.fileFormat.settings,
                commonFormat: src.processingFormat.commonFormat,
                interleaved: src.processingFormat.isInterleaved)
            let chunk: AVAudioFrameCount = 1 << 16
            guard let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: chunk) else {
                throw TrimError.noAudio
            }
            src.framePosition = start
            var left = end - start
            while left > 0 {
                try src.read(into: buf, frameCount: AVAudioFrameCount(min(Int64(chunk), left)))
                if buf.frameLength == 0 { break }
                try dst.write(from: buf)
                left -= AVAudioFramePosition(buf.frameLength)
            }
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return Int64(Double(end - start) / rate * 1000)
    }

    private static func trimVideo(url: URL, startSec: Double, endSec: Double) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TrimError.noAudio
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".trim-video.mov")
        try? FileManager.default.removeItem(at: tmp)
        let scale: CMTimeScale = 600
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: scale),
            end: CMTime(seconds: endSec, preferredTimescale: scale))
        try await export.export(to: tmp, as: .mov)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
