//
//  FileBoxManager.swift
//  TmpspaceMenuBar
//
//  Manages temporary file storage for floating panels.
//  All panels share a single user-configurable folder.
//

import Foundation

/// Manages the lifecycle of files dropped into a panel's file box.
///
/// Files are copied into a user-configurable folder.
/// In sandbox the default is the app container's Documents/Tmpspace/;
/// outside sandbox the default is ~/Documents/Tmpspace/.
@MainActor
public final class FileBoxManager {

    public init() {}

    /// UserDefaults key for the shared file box folder path.
    private static let folderPathKey = "fileBoxFolderPath"

    /// UserDefaults key for the security-scoped bookmark (sandbox persisted access).
    private static let bookmarkKey = "fileBoxFolderBookmark"

    /// Retains the security-scoped URL so the kernel doesn't revoke access.
    private static var securedFolderURL: URL?

    // MARK: - Sandbox detection

    /// `true` when the app is running inside the macOS App Sandbox.
    private static var isSandboxed: Bool {
        let containerBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tmpspace.app")
        return FileManager.default.fileExists(atPath: containerBase.path)
    }

    /// Default folder when no user-chosen folder is configured.
    private static var defaultFolderURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if isSandboxed {
            // App sandbox container Documents — always writable without bookmarks.
            return home
                .appendingPathComponent("Library/Containers/com.tmpspace.app/Data/Documents/Tmpspace",
                                        isDirectory: true)
        }
        return home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Tmpspace", isDirectory: true)
    }

    /// Resolve the working folder: security-scoped bookmark first, then
    /// the plain path from UserDefaults, then the default location.
    public static func resolveFolderURL() -> URL {
        // 1. Try restoring a security-scoped bookmark (sandbox-safe).
        if let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if resolved.startAccessingSecurityScopedResource() {
                    securedFolderURL = resolved  // retain access for app lifetime
                    if isStale {
                        // Re-save a fresh bookmark.
                        saveBookmark(for: resolved)
                    }
                    return resolved
                }
            }
        }

        // 2. Try the plain path (legacy, non-sandbox).
        let raw = UserDefaults.standard.string(forKey: folderPathKey) ?? ""
        if !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // 3. Fall back to the default.
        return defaultFolderURL
    }

    /// The shared folder all files are stored in.
    public static var folderURL: URL {
        get { resolveFolderURL() }
        set {
            let path = newValue.path
            UserDefaults.standard.set(path, forKey: folderPathKey)
            // Ensure the new directory exists.
            if !FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.createDirectory(
                    at: newValue,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
            Self.ensureWatching()
        }
    }

    /// Create and persist a security-scoped bookmark for the given URL.
    public static func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        folderURL = url
    }

    /// Release security-scoped access. Call on app termination.
    public static func stopSecurityScopedAccess() {
        if let url = securedFolderURL {
            url.stopAccessingSecurityScopedResource()
            securedFolderURL = nil
        }
    }

    // MARK: - File operations

    /// List all files in the shared folder.
    func files() -> [URL] {
        Self.ensureWatching()
        let dir = Self.folderURL
        return (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
    }

    /// Copy or move a file into the shared folder. Returns the destination URL.
    /// Mode is read from UserDefaults `"fileBoxMode"` — `"copy"` (default) or `"move"`.
    public func addFile(_ sourceURL: URL) -> URL? {
        let dir = Self.folderURL
        let destURL = dir.appendingPathComponent(sourceURL.lastPathComponent)

        // Handle name collisions by appending a number.
        var uniqueURL = destURL
        var counter = 1
        while FileManager.default.fileExists(atPath: uniqueURL.path) {
            let stem = destURL.deletingPathExtension().lastPathComponent
            let ext = destURL.pathExtension
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            uniqueURL = dir.appendingPathComponent(name)
            counter += 1
        }

        let mode = UserDefaults.standard.string(forKey: "fileBoxMode") ?? "copy"
        do {
            if mode == "move" {
                try FileManager.default.moveItem(at: sourceURL, to: uniqueURL)
            } else {
                try FileManager.default.copyItem(at: sourceURL, to: uniqueURL)
            }
            return uniqueURL
        } catch {
            DebugLog.log("FileBoxManager: failed to \(mode) \(sourceURL.path): \(error)")
            return nil
        }
    }

    /// Delete a specific file from storage.
    func deleteFile(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Directory watching

    /// Posted when the file box folder contents change externally.
    public static let fileBoxDidChangeNotification = Notification.Name("TmpspaceFileBoxDidChange")

    private nonisolated(unsafe) static var directoryWatcherFD: Int32 = -1
    private nonisolated(unsafe) static var directoryWatcher: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) static var watcherDebounceItem: DispatchWorkItem?
    private nonisolated(unsafe) static var watchedPath: String?
    private static let watcherQueue = DispatchQueue(label: "com.tmpspace.filebox.watcher")

    /// Ensure the directory watcher is running for the current folder.
    static func ensureWatching() {
        let current = resolveFolderURL().path
        guard watchedPath != current else { return }
        startWatching()
    }

    /// Start monitoring the file box folder for external changes.
    static func startWatching() {
        stopWatching()

        let folderPath = resolveFolderURL().path
        if !FileManager.default.fileExists(atPath: folderPath) {
            try? FileManager.default.createDirectory(
                atPath: folderPath,
                withIntermediateDirectories: true
            )
        }

        let fd = open(folderPath, O_EVTONLY)
        guard fd >= 0 else { return }

        watchedPath = folderPath
        directoryWatcherFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: watcherQueue
        )

        source.setEventHandler {
            watcherDebounceItem?.cancel()
            let item = DispatchWorkItem {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: fileBoxDidChangeNotification,
                        object: nil
                    )
                }
            }
            watcherDebounceItem = item
            watcherQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        directoryWatcher = source
    }

    /// Stop monitoring the file box folder.
    static func stopWatching() {
        watcherDebounceItem?.cancel()
        watcherDebounceItem = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
        if directoryWatcherFD >= 0 {
            close(directoryWatcherFD)
            directoryWatcherFD = -1
        }
        watchedPath = nil
    }
}
