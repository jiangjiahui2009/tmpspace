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
/// Files are copied into a user-configurable folder (default: ~/Documents/Tmpspace/).
/// The folder can be changed in Preferences > General.
@MainActor
final class FileBoxManager {

    /// UserDefaults key for the shared file box folder path.
    private static let folderPathKey = "fileBoxFolderPath"

    /// Default folder: ~/Documents/Tmpspace/
    private static var defaultFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Tmpspace", isDirectory: true)
    }

    /// The shared folder all files are stored in.
    static var folderURL: URL {
        get {
            let raw = UserDefaults.standard.string(forKey: folderPathKey) ?? ""
            let url = raw.isEmpty
                ? defaultFolderURL
                : URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            // Ensure the directory exists.
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
            return url
        }
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
        }
    }

    // MARK: - File operations

    /// List all files in the shared folder.
    func files() -> [URL] {
        let dir = Self.folderURL
        return (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
    }

    /// Copy or move a file into the shared folder. Returns the destination URL.
    /// Mode is read from UserDefaults `"fileBoxMode"` — `"copy"` (default) or `"move"`.
    func addFile(_ sourceURL: URL) -> URL? {
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
}
