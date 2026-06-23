import Foundation

struct RangeRequest: Equatable {
    let start: Int64
    let end: Int64
    var length: Int64 { end - start + 1 }

    static func parse(_ header: String, fileSize: Int64) -> RangeRequest? {
        guard fileSize > 0 else { return nil }
        guard header.hasPrefix("bytes=") else { return nil }
        let body = header.dropFirst("bytes=".count)
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let lhs = parts[0].trimmingCharacters(in: .whitespaces)
        let rhs = parts[1].trimmingCharacters(in: .whitespaces)

        let last = fileSize - 1

        if lhs.isEmpty {
            guard let n = Int64(rhs), n > 0 else { return nil }
            let start = max(0, fileSize - n)
            return RangeRequest(start: start, end: last)
        }

        guard let start = Int64(lhs) else { return nil }
        if rhs.isEmpty {
            // Open-ended `start-`: reject start past EOF, else end < start
            // gives a negative content-length (the explicit-end branch below
            // already guards this; the open-ended one didn't).
            guard start <= last else { return nil }
            return RangeRequest(start: start, end: last)
        }
        guard let endParsed = Int64(rhs) else { return nil }
        let end = min(endParsed, last)
        guard start <= end else { return nil }
        return RangeRequest(start: start, end: end)
    }
}
