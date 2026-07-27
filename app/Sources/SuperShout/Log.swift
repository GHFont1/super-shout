import Foundation

/// File logger (~/Library/Logs/SuperShout.log) — NSLog from an LSUIElement
/// app is effectively invisible in the unified log, and dictation bugs need
/// a traceable timeline.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SuperShout.log")
    private static let queue = DispatchQueue(label: "supershout.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        NSLog("SuperShout: %@", message)
        queue.async {
            let line = "\(stamp.string(from: Date())) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
