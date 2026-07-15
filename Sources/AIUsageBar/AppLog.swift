import Foundation

/// Tiny file logger for diagnostics, viewable from Settings.
/// Writes timestamped lines to ~/Library/Logs/AIUsageBar/AIUsageBar.log and
/// trims the file when it grows past ~512KB so it can never balloon.
final class AppLog {
    static let shared = AppLog()

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.perth.aiusagebar.applog")
    private let timestamp: DateFormatter

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AIUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("AIUsageBar.log")
        timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    func log(_ message: String) {
        let line = "\(timestamp.string(from: Date())) \(message)\n"
        queue.async {
            self.trimIfNeeded()
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try? line.write(to: self.fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Last `maxLines` lines for the Settings viewer.
    func tail(_ maxLines: Int = 200) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    func clear() {
        queue.sync { try? "".write(to: fileURL, atomically: true, encoding: .utf8) }
    }

    private func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int,
              size > 512_000,
              let text = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

func appLog(_ message: String) { AppLog.shared.log(message) }
