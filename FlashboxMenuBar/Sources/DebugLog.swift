import Foundation

/// Simple file-based logger for debugging app launch issues.
public enum DebugLog {
    private static let logFileURL: URL = URL(fileURLWithPath: "/tmp/flashbox-debug.log")

    public static func log(_ message: String) {
        let line = "\(Date()) [Flashbox] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }
}
