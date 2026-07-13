import AVFoundation
import Foundation

/// Remuxes a crash-safe FRAGMENTED `.mov` (what `AVAssetWriter` writes with
/// `movieFragmentInterval`) into a FASTSTART file whose `moov` atom sits at the
/// front, so the WKWebView `<video>` element can progressively load it.
///
/// Why both forms exist: a faststart writer buffers the whole movie and flushes
/// the `moov`+`mdat` only on `finishWriting`, so a recording interrupted by a
/// hard kill (an app update, the `terminateOtherInstances` deploy reap, power
/// loss) leaves a ZERO-byte video.mov, total video loss (measured). Fragmented
/// writing flushes a self-describing chunk to disk every few seconds, so the
/// file stays valid up to the last flush. But a fragmented QuickTime MOV can't
/// be progressively loaded by WKWebView (its `moov` isn't at the front), which
/// historically made a recorded video look like "no video captured". So the
/// capture writer stays fragmented for crash-safety and this pays off the
/// playback cost LAZILY at serve time: the first time the video is requested we
/// remux it once, in place, and every later request serves the faststart file
/// straight from disk.
///
/// Verified on a REAL kill-interrupted capture: a fragmented file laid out
/// `ftyp/wide/mdat/moov/…/moof/…` (6.3 s recovered) remuxes via a passthrough
/// export (no re-encode) into `ftyp/moov/wide/mdat` (faststart), preserving the
/// full duration.
enum VideoRemux {
    /// If `url` is a non-faststart (fragmented) MP4/MOV, remux it to a faststart
    /// file in place. No-op on an already-faststart file (idempotent, safe to
    /// call before every serve). Blocking, call off the main thread (a Swifter
    /// worker). Returns true if it remuxed.
    @discardableResult
    static func faststartIfNeeded(at url: URL) -> Bool {
        guard needsFaststart(url) else { return false }

        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            FileLogger.log("VideoRemux: no export session for \(url.lastPathComponent)")
            return false
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("video-faststart-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: tmp)
        export.outputURL = tmp
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = true   // moov to the front (faststart)

        let sema = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sema.signal() }
        sema.wait()

        guard export.status == .completed,
              FileManager.default.fileExists(atPath: tmp.path) else {
            FileLogger.log("VideoRemux: export failed for \(url.lastPathComponent): \(export.error?.localizedDescription ?? "?") (status \(export.status.rawValue))")
            try? FileManager.default.removeItem(at: tmp)
            return false
        }

        // Swap the fragmented original for the faststart file (atomic same-volume).
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            FileLogger.log("VideoRemux: faststarted \(url.lastPathComponent)")
            return true
        } catch {
            FileLogger.log("VideoRemux: replace failed for \(url.lastPathComponent): \(error)")
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// A file needs a faststart remux when its `moov` is NOT at the front, i.e.
    /// the media `mdat` is reached before any `moov`. Walk the top-level
    /// ISO-BMFF boxes: `moov` first → faststart (leave it); `mdat` first →
    /// fragmented / non-faststart (remux). Reads only box headers (skips the
    /// media payload by size), and the decision lands within the first few
    /// boxes. Verified against both real layouts: faststart `ftyp/moov/mdat`
    /// (→ false) and fragmented `ftyp/wide/mdat/moov/…` (→ true).
    private static func needsFaststart(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var offset: UInt64 = 0
        for _ in 0..<64 {
            guard (try? h.seek(toOffset: offset)) != nil,
                  let data = try? h.read(upToCount: 8), data.count == 8 else { return false }
            let b = [UInt8](data)
            var size: UInt64 = 0
            for i in 0..<4 { size = (size << 8) | UInt64(b[i]) }   // big-endian box size
            let type = String(bytes: b[4..<8], encoding: .ascii) ?? ""
            if type == "moov" { return false }
            if type == "mdat" { return true }
            if size == 1 {
                // 64-bit largesize follows the 8-byte header.
                guard let ext = try? h.read(upToCount: 8), ext.count == 8 else { return false }
                let e = [UInt8](ext)
                size = 0
                for i in 0..<8 { size = (size << 8) | UInt64(e[i]) }
            }
            if size < 8 { return false }   // to-EOF (0) or malformed, stop probing
            offset += size
        }
        return false
    }
}
