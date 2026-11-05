import AVFoundation
import Foundation

/// Cuts a recording down to one time range, in place, so only that part is
/// transcribed and kept. Used on an un-transcribed session (the recording ran
/// for hours after the meeting ended): the user picks the range on the player
/// timeline and everything outside it is deleted from disk.
///
/// Every track is cut by the same range, so mic / system / video stay aligned
/// (they all start at the same capture instant).
///
/// NEVER destructive: the first trim moves the original files into
/// `.untrimmed/` (a same-volume rename, instant) and `restore` puts them back.
/// 0.15.123 deleted the rest outright and a misplaced range cost a user the
/// whole meeting it was meant to keep.
enum RecordingTrimmer {
    enum TrimError: Error { case badRange, noAudio, noBackup }

    struct Original: Codable { var startedAt: Int64; var durationMs: Int64?; var endedAt: Int64? }

    static func backupDir(_ dir: URL) -> URL { dir.appendingPathComponent(".untrimmed", isDirectory: true) }
    static func hasBackup(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: backupDir(dir).appendingPathComponent("original.json").path)
    }

    /// Moves the originals aside (once; a second trim keeps the first originals)
    /// and records the row's original timing so `restore` can put it back.
    static func backUpOriginals(dir: URL, original: Original) throws {
        let fm = FileManager.default
        let bak = backupDir(dir)
        guard !hasBackup(dir) else {
            // Re-trim: work from copies of the current (already trimmed) files.
            return
        }
        try fm.createDirectory(at: bak, withIntermediateDirectories: true)
        for name in audioFiles + ["video.mov"] {
            let src = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = bak.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
            try fm.copyItem(at: dst, to: src)   // APFS clone: instant, no extra space
        }
        try JSONEncoder().encode(original).write(to: bak.appendingPathComponent("original.json"))
    }

    /// Puts the untouched originals back and returns the row's original timing.
    static func restore(dir: URL) throws -> Original {
        let fm = FileManager.default
        let bak = backupDir(dir)
        guard let data = try? Data(contentsOf: bak.appendingPathComponent("original.json")),
              let original = try? JSONDecoder().decode(Original.self, from: data) else { throw TrimError.noBackup }
        for name in audioFiles + ["video.mov"] {
            let src = bak.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        }
        try? fm.removeItem(at: bak)
        return original
    }

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
