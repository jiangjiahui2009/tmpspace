//
//  EditorDisplaySettings.swift
//  TmpspaceCore
//
//  Codable model for editor display preferences, persisted in UserDefaults.
//

import AppKit

/// Editor display settings — persisted in UserDefaults under the key
/// `"editorDisplaySettings"`. Each change broadcasts `editorDisplaySettingsDidChange`
/// so panels can apply the new values immediately.
public struct EditorDisplaySettings: Codable, Equatable, Sendable {

    /// Font family for the editor. Default `"system-ui"`.
    public var fontFamily: String

    /// Font weight (e.g., `"regular"`, `"bold"`). `nil` means default weight.
    public var fontWeight: String?

    /// Font style (e.g., `"normal"`, `"italic"`). `nil` means default style.
    public var fontStyle: String?

    /// Font size in points. Default `16`.
    public var fontSize: Double

    /// Syntax highlighting theme name (e.g. `"github-dark"`, `"xcode-light"`).
    /// Default `"system"`.
    public var theme: String

    /// Show line numbers in the left gutter. Default `false`.
    public var showLineNumbers: Bool

    /// Highlight the line the cursor is currently on. Default `false`.
    public var showActiveLineIndicator: Bool

    /// Line-height multiplier (1.4 compact / 1.6 normal / 1.8 relaxed).
    /// Default `1.6`.
    public var lineHeight: Double

    /// Play a sound effect when a task list checkbox is toggled. Default `true`.
    public var taskToggleSound: Bool

    /// When `true`, the toolbar uses a solid opaque background.
    /// When `false` (default), the toolbar shows a frosted-glass blur effect.
    public var reduceToolbarTransparency: Bool

    /// Returns `true` when the syntax theme is dark.
    ///
    /// For `"system"`, delegates to the current OS appearance (dark Aqua = dark).
    /// Otherwise matches against known dark theme names.
    public var isDarkTheme: Bool {
        if theme == "system" {
            let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return name == .darkAqua
        }
        // Dark themes: names containing "dark", or known dark-only names.
        let knownDark = [
            "dracula", "cobalt", "synthwave84", "night-owl", "rose-pine",
        ]
        if knownDark.contains(theme) { return true }
        return theme.contains("dark")
    }

    /// Toolbar / window chrome background color derived from the theme.
    public var chromeColor: NSColor {
        isDarkTheme
            ? NSColor(white: 0.15, alpha: 1)
            : NSColor(white: 0.97, alpha: 1)
    }

    /// Effective window appearance derived from the theme.
    public var effectiveAppearance: NSAppearance? {
        isDarkTheme
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }

    // MARK: - Init

    public init(
        fontFamily: String = "system-ui",
        fontWeight: String? = nil,
        fontStyle: String? = nil,
        fontSize: Double = 16,
        theme: String = "system",
        showLineNumbers: Bool = true,
        showActiveLineIndicator: Bool = false,
        lineHeight: Double = 1.6,
        taskToggleSound: Bool = true,
        reduceToolbarTransparency: Bool = true
    ) {
        self.fontFamily = fontFamily
        self.fontWeight = fontWeight
        self.fontStyle = fontStyle
        self.fontSize = fontSize
        self.theme = theme
        self.showLineNumbers = showLineNumbers
        self.showActiveLineIndicator = showActiveLineIndicator
        self.lineHeight = lineHeight
        self.taskToggleSound = taskToggleSound
        self.reduceToolbarTransparency = reduceToolbarTransparency
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when the user changes editor display settings in the preferences
    /// window so that all open panels can apply the new values immediately.
    public static let editorDisplaySettingsDidChange = Notification.Name("EditorDisplaySettingsDidChange")

    /// Posted when panel visibility changes (show / hide).
    /// MenuBarController observes this to animate the status bar icon.
    public static let tmpspacePanelsVisibilityDidChange = Notification.Name("TmpspacePanelsVisibilityDidChange")

    /// Posted when the user toggles "Always on Top" in Settings.
    /// PanelManager observes this to update all existing panel window levels.
    public static let tmpspaceAlwaysOnTopDidChange = Notification.Name("TmpspaceAlwaysOnTopDidChange")

    /// Posted when files are dragged over the editor WebView area.
    /// `FloatingPanelController` observes this to auto-expand the file box.
    public static let tmpspaceEditorDragEntered = Notification.Name("TmpspaceEditorDragEntered")

    /// Posted when files are dropped onto the editor WebView.
    /// The `userInfo` contains `"urls"` — an `[URL]` of temp files written from the drop data.
    public static let tmpspaceEditorDidReceiveFiles = Notification.Name("TmpspaceEditorDidReceiveFiles")

    /// Posted when files are dropped into the menu bar drop zone (panels hidden).
    /// FloatingPanelController observes this to refresh its file box when shown.
    public static let tmpspaceDropZoneDidReceiveFiles = Notification.Name("TmpspaceDropZoneDidReceiveFiles")

    /// Posted when the user selects a custom menu bar icon in Settings.
    /// MenuBarController observes this to update the status bar icon immediately.
    public static let tmpspaceMenuBarIconDidChange = Notification.Name("TmpspaceMenuBarIconDidChange")
}

// MARK: - UserDefaults persistence

public extension EditorDisplaySettings {
    /// UserDefaults key for the encoded settings.
    static let storageKey = "editorDisplaySettings"

    /// Read the currently persisted settings, or return the default values.
    static func load() -> EditorDisplaySettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(EditorDisplaySettings.self, from: data)
        else {
            return EditorDisplaySettings()
        }
        return settings
    }

    /// Persist these settings to UserDefaults and post the change notification.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        NotificationCenter.default.post(name: .editorDisplaySettingsDidChange, object: nil)
    }
}
