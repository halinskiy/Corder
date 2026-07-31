import AVFoundation
import Foundation

/// On-demand export helpers for the Download chooser. Two products:
///
///   • audio-only  → AAC `.m4a`. The on-disk mix is a 16 kHz mono
///     **Float32** `audio.wav` (~560 MB for a 2.5 h call); AAC is ~10×
///     smaller for the same speech, so the user isn't handed a
///     half-gigabyte WAV when they just want the audio.
///
///   • video+audio → the SILENT screen `video.mov` (we capture audio as
///     separate tracks, the movie has no sound) remuxed WITH the mixed
///     audio into one `.mp4`. The video is copied **verbatim**
///     (passthrough, no re-encode), so a 2.5 h HEVC capture muxes in
///     seconds instead of the many minutes a full transcode would burn.
///     Only the audio is (re-)encoded to AAC, which is why we build the
///     `.m4a` first and reuse it as the mux's audio source.
///
/// Both products cache into a temp exports dir keyed by meeting id and
/// are regenerated only when a source file is newer than the cached
/// export. Temp (not the recordings dir) on purpose: a download is a
/// one-off, and we don't want a 1.6 GB derived file lingering next to
/// the originals or getting swept into a Dropbox archive.
enum MediaExporter {
    private static func exportsDir(for id: String) -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corder-exports", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// True when `output` exists and is at least as new as every source.
    private static func isFresh(_ output: URL, newerThan sources: [URL]) -> Bool {
        let fm = FileManager.default
        guard let outAttr = try? fm.attributesOfItem(atPath: output.path),
              let outDate = outAttr[.modificationDate] as? Date,
              ((outAttr[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { return false }
        for s in sources {
            guard let a = try? fm.attributesOfItem(atPath: s.path),
                  let d = a[.modificationDate] as? Date else { continue }
            if d > outDate { return false }
        }
        return true
    }

    /// Synchronous wrapper around `AVAssetExportSession`, Swifter request
    /// handlers are blocking, so we drive the async export to completion
    /// on a semaphore rather than hopping threads.
    private static func runExport(_ session: AVAssetExportSession) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        session.exportAsynchronously { sem.signal() }
        sem.wait()
        if session.status != .completed {
            FileLogger.log("MediaExporter: export failed, \(session.error?.localizedDescription ?? "unknown") (status \(session.status.rawValue))")
        }
        return session.status == .completed
    }

    /// `audio.wav` → AAC `.m4a`. Returns the cached m4a URL, or nil when
    /// there's no mix on disk or the encode failed.
    static func audioM4A(meetingId id: String) -> URL? {
        let dir = AppPaths.recordingDir(for: id)
        let src = dir.appendingPathComponent("audio.wav")
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let out = exportsDir(for: id).appendingPathComponent("corder-\(id).m4a")
        if isFresh(out, newerThan: [src]) { return out }
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        session.outputURL = out
        session.outputFileType = .m4a
        return runExport(session) ? out : nil
    }

    /// `audio.wav` → AAC `.m4a` clipped to `[startMs, endMs)`. Same encode as
    /// `audioM4A`, plus an export `timeRange` so the file physically contains
    /// ONLY the shared range: a share clip must never ship the rest of the
    /// meeting's audio. The cache name carries the range so distinct clips of
    /// one meeting don't overwrite each other's export.
    static func audioClipM4A(meetingId id: String, startMs: Int, endMs: Int) -> URL? {
        let dir = AppPaths.recordingDir(for: id)
        let src = dir.appendingPathComponent("audio.wav")
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        guard endMs - startMs >= 1000 else { return nil }
        let out = exportsDir(for: id).appendingPathComponent("corder-\(id)-\(startMs)-\(endMs).m4a")
        if isFresh(out, newerThan: [src]) { return out }
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        session.outputURL = out
        session.outputFileType = .m4a
        // Clamp to the asset so a range past the end just yields a shorter clip
        // instead of failing the export.
        let ms = 1000
        let start = CMTime(value: CMTimeValue(startMs), timescale: CMTimeScale(ms))
        let end = CMTime(value: CMTimeValue(endMs), timescale: CMTimeScale(ms))
        let full = CMTimeRange(start: .zero, duration: asset.duration)
        let want = CMTimeRange(start: start, end: end)
        session.timeRange = full.intersection(want)
        return runExport(session) ? out : nil
    }

    /// `video.mov` (silent) + `audio.wav` → one `.mp4` with an AAC audio
    /// track. Video passthrough, audio re-encoded (via the cached m4a).
    /// `videoPath` is the meeting's stored video location (the canonical
    /// name is `video.mov`, but we take it from the DB to be safe).
    static func videoWithAudio(meetingId id: String, videoPath: String) -> URL? {
        let vURL = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: vURL.path) else { return nil }
        guard let aURL = audioM4A(meetingId: id) else { return nil }
        let out = exportsDir(for: id).appendingPathComponent("corder-\(id).mp4")
        if isFresh(out, newerThan: [vURL, aURL]) { return out }
        try? FileManager.default.removeItem(at: out)

        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: vURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let aAsset = AVURLAsset(url: aURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vSrc = vAsset.tracks(withMediaType: .video).first,
              let aSrc = aAsset.tracks(withMediaType: .audio).first,
              let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            FileLogger.log("MediaExporter: missing source track for \(id) (video or audio)")
            return nil
        }
        let vDur = vAsset.duration
        do {
            try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
            vTrack.preferredTransform = vSrc.preferredTransform
            // Clamp the audio to the video length, they're recorded
            // together so they should match, but a stop-time race can
            // leave one a few frames longer; trimming avoids a tail of
            // black video or silent audio.
            let useDur = CMTimeMinimum(vDur, aAsset.duration)
            try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: useDur), of: aSrc, at: .zero)
        } catch {
            FileLogger.log("MediaExporter: composition insert failed for \(id), \(error)")
            return nil
        }
        // Passthrough = copy both tracks as-is. The video stays HEVC (no
        // re-encode); the audio is already AAC from the m4a step, so the
        // whole mux is a fast remux, not a transcode.
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return nil }
        session.outputURL = out
        session.outputFileType = .mp4
        return runExport(session) ? out : nil
    }
}
