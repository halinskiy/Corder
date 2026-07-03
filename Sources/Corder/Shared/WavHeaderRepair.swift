import Foundation

/// Repairs a WAV file whose header was never finalized — the case after a
/// hard kill (SIGKILL / power loss / a `terminateOtherInstances` reap during
/// a deploy) mid-recording.
///
/// `AVAudioFile` writes the RIFF chunk size and the `data` sub-chunk size
/// ONLY when the file is closed (on `stop()` / deallocation). A process killed
/// mid-capture therefore leaves a file that is FULL of valid audio bytes on
/// disk but whose header still says `data` size = 0 (and a header-only RIFF
/// size). Every reader — `AVAudioFile(forReading:)`, `afinfo`, the
/// transcription pipeline — then computes ZERO frames, so the recording looks
/// empty and `RecordingRecovery` discards it as "unsalvageable" even though
/// minutes of audio are sitting right there. (Verified: a killed `mic.wav` of
/// 380 KB reported `estimated duration: 0.000000 sec`.)
///
/// This patches the two size fields in place from the real file length, so the
/// captured audio becomes readable / playable / transcribable again. It is a
/// no-op on an already-finalized file (the stored size already matches), so it
/// is safe to call unconditionally on any WAV before reading it.
enum WavHeaderRepair {
    /// Patch the `data` sub-chunk size + outer RIFF size to reflect the bytes
    /// actually on disk. Returns true if it repaired a truncated-header file,
    /// false if the file was already valid / unreadable / not a PCM WAV.
    @discardableResult
    static func repairIfTruncated(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }

        guard let sizeAttr = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              sizeAttr > 44 else { return false }
        let fileSize = sizeAttr

        // The audio `data` chunk can sit a few KB in — AVAudioFile pads with a
        // FLLR filler chunk to block-align the samples — so read a generous
        // prefix to walk the chunk list.
        let headerCap = min(fileSize, 64 * 1024)
        guard let raw = try? handle.read(upToCount: headerCap) else { return false }
        let head = [UInt8](raw)
        guard head.count >= 12,
              head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46  // "RIFF"
        else { return false }

        func u32(_ o: Int) -> Int {
            Int(head[o]) | (Int(head[o + 1]) << 8) | (Int(head[o + 2]) << 16) | (Int(head[o + 3]) << 24)
        }
        func u16(_ o: Int) -> Int { Int(head[o]) | (Int(head[o + 1]) << 8) }
        func isTag(_ o: Int, _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
            head[o] == a && head[o + 1] == b && head[o + 2] == c && head[o + 3] == d
        }

        var blockAlign = 4                 // 1ch float32 default; overwritten from fmt
        var off = 12                       // skip "RIFF" + size + "WAVE"
        var dataSizeFieldOffset = -1
        var dataContentStart = -1
        while off + 8 <= head.count {
            let sz = u32(off + 4)
            if isTag(off, 0x66, 0x6d, 0x74, 0x20), off + 8 + 16 <= head.count {   // "fmt "
                let ba = u16(off + 8 + 12)
                if ba > 0 { blockAlign = ba }
            }
            if isTag(off, 0x64, 0x61, 0x74, 0x61) {                              // "data"
                dataSizeFieldOffset = off + 4
                dataContentStart = off + 8
                break
            }
            off += 8 + sz + (sz & 1)       // chunks are word-aligned
        }
        guard dataSizeFieldOffset >= 0, dataContentStart >= 0, dataContentStart <= fileSize else { return false }

        let storedDataSize = u32(dataSizeFieldOffset)
        // Trim a partial final frame so the length is a whole number of frames.
        var realDataSize = fileSize - dataContentStart
        realDataSize -= realDataSize % max(1, blockAlign)
        // Only ever GROW the claimed size (the kill case: stored 0 vs real
        // bytes present). Never shrink a file the header already describes —
        // that would corrupt a valid recording.
        guard realDataSize > 0, realDataSize > storedDataSize else { return false }

        let newEnd = dataContentStart + realDataSize
        func writeU32LE(_ value: Int, at offset: Int) {
            var le = UInt32(truncatingIfNeeded: value).littleEndian
            let bytes = withUnsafeBytes(of: &le) { Data($0) }
            try? handle.seek(toOffset: UInt64(offset))
            try? handle.write(contentsOf: bytes)
        }
        writeU32LE(realDataSize, at: dataSizeFieldOffset)   // data sub-chunk size
        writeU32LE(newEnd - 8, at: 4)                       // outer RIFF size
        try? handle.truncate(atOffset: UInt64(newEnd))      // drop any partial trailing frame
        try? handle.synchronize()
        FileLogger.log("WavHeaderRepair: patched \(url.lastPathComponent) data \(storedDataSize)→\(realDataSize) bytes (blockAlign=\(blockAlign))")
        return true
    }
}
