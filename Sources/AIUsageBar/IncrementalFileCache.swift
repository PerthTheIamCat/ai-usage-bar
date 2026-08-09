import Foundation

/// The newly-appended region of an append-only log.
struct IncrementalRead {
    /// Whole lines only — a trailing partial line (the writer was mid-append
    /// when we looked) is left for the next read.
    let data: Data
    /// True when the file could not be continued from the previous offset and
    /// was re-read from the start, so the caller must discard whatever state
    /// it had accumulated for this file.
    let isReset: Bool
    /// Byte offset to resume from next time.
    let consumed: Int
}

/// Reads only what has been appended to `url` since byte `consumed`.
///
/// Claude Code and Codex write their session logs by appending whole JSON
/// lines and never rewriting earlier ones, so a refresh that finds a file
/// 40 KB longer than last time has 40 KB of new work — not the 34 MB the file
/// has grown to. That distinction is the difference between a menu-bar app
/// that costs nothing during a long coding session and one macOS flags for
/// energy use.
///
/// Returns nil when there is nothing new. A file that shrank (rotated,
/// rewritten, replaced by a different session) can't be continued, so it is
/// re-read whole and flagged with `isReset`.
func incrementalRead(of url: URL, from consumed: Int) -> IncrementalRead? {
    // Deliberately not `url.resourceValues(forKeys: [.fileSizeKey])`: `URL`
    // caches resource values on the instance, so a URL that outlives one call
    // keeps reporting the size the file had the first time it was asked — and
    // this function's whole job is noticing that a file grew.
    guard let sizeHandle = try? FileHandle(forReadingFrom: url),
          let fileSize = try? sizeHandle.seekToEnd()
    else { return nil }
    try? sizeHandle.close()
    let size = Int(fileSize)
    guard size > 0 else { return nil }

    let isReset = consumed > size
    let offset = isReset ? 0 : consumed
    guard size > offset else { return nil }

    let data: Data
    if offset == 0 {
        // First look at a file that may be 100+ MB. Map it rather than
        // reading it into the heap, so untouched regions stay out of the
        // app's footprint and the kernel can evict what has been walked past.
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        data = mapped
    } else {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        guard let appended = try? handle.readToEnd() else { return nil }
        data = appended
    }
    guard !data.isEmpty else { return nil }

    // Stop at the last complete line. Anything after it is a partial write
    // that would fail to parse now and be lost forever once the offset moved
    // past it. Slicing (rather than copying out a subrange) keeps a mapped
    // file mapped instead of pulling all of it into memory.
    guard let lastNewline = data.lastIndex(of: 0x0A) else { return nil }
    let usable = data[data.startIndex..<data.index(after: lastNewline)]
    return IncrementalRead(
        data: usable,
        isReset: isReset,
        consumed: offset + usable.count)
}

/// Per-file parse state carried between refreshes, so each line of a log is
/// parsed exactly once no matter how many times the file is looked at.
///
/// `State` must be a value type: entries are handed out by copy, so a caller
/// can read a state while another thread advances the cache.
final class IncrementalFileCache<State> {
    private struct Entry {
        var consumed: Int
        var state: State
        var lastUsed: Date
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    /// Long enough that a file quiet for a while (an idle session someone
    /// comes back to) keeps its parsed state, short enough that a month of
    /// rotating session files can't accumulate.
    private let unusedEntryLifetime: TimeInterval = 2 * 3600

    /// Brings each file up to date and returns the resulting states, in the
    /// order given. `consume` receives only newly-appended bytes.
    func states(
        for files: [URL],
        initial: () -> State,
        consume: (Data, inout State) -> Void
    ) -> [State] {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        var result: [State] = []
        result.reserveCapacity(files.count)
        for url in files {
            var entry = entries[url.path] ?? Entry(consumed: 0, state: initial(), lastUsed: now)
            if let read = incrementalRead(of: url, from: entry.consumed) {
                if read.isReset { entry.state = initial() }
                consume(read.data, &entry.state)
                entry.consumed = read.consumed
            }
            entry.lastUsed = now
            entries[url.path] = entry
            result.append(entry.state)
        }

        let cutoff = now.addingTimeInterval(-unusedEntryLifetime)
        entries = entries.filter { $0.value.lastUsed >= cutoff }
        return result
    }

    /// Tests only — the caches are process-wide statics otherwise.
    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
