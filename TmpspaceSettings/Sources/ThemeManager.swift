//
//  ThemeManager.swift
//  TmpspaceSettings
//
//  Manages system appearance adaptation, observing light/dark mode switches
//  and broadcasting notifications so panel chrome and editor content can
//  update in response.
//

import AppKit

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the system appearance changes (e.g., light to dark mode).
    static let systemAppearanceDidChange = Notification.Name("SystemAppearanceDidChange")
}

// MARK: - Appearance Name

/// Represents the current system appearance state.
public enum SystemAppearanceName: String, Sendable {
    case light
    case dark

    /// Returns `true` if the system is currently in dark mode.
    public var isDark: Bool {
        self == .dark
    }
}

// MARK: - User Defaults Key

/// If `true`, the app forces light mode regardless of system setting.
/// If `false`, the app forces dark mode regardless of system setting.
/// If `nil` (default), the app follows the system appearance.
private let forceAppearanceKey = "forceAppearanceOverride"

// MARK: - ThemeManager

/// Observes `NSApp.effectiveAppearance` changes and posts notifications
/// so that panel UI can recompute colors when the system appearance toggles.
///
/// Also supports a user preference override to force light or dark mode,
/// which takes precedence over the system setting.
@MainActor
public final class ThemeManager: NSObject {

    // MARK: - Shared Instance

    public static let shared = ThemeManager()

    // MARK: - Private State

    /// KVO observation token for `NSApp.effectiveAppearance`.
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Init

    private override init() {
        super.init()
        beginObservingAppearance()
    }

    // MARK: - Public API

    /// Returns the effective appearance name, accounting for any user override.
    ///
    /// - If `forceAppearanceOverride` is `"light"` or `"dark"`, that value is returned.
    /// - Otherwise, the current `NSApp.effectiveAppearance` best match is returned.
    public static var currentAppearanceName: SystemAppearanceName {
        if let override = UserDefaults.standard.string(forKey: forceAppearanceKey) {
            if override == "light" { return .light }
            if override == "dark"  { return .dark }
        }

        // Determine from the effective appearance name
        let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        switch name {
        case .darkAqua:
            return .dark
        default:
            return .light
        }
    }

    /// Returns `true` when the effective appearance is dark (or forced dark).
    public static var isDarkMode: Bool {
        currentAppearanceName == .dark
    }

    /// Force a specific appearance mode, overriding the system setting.
    ///
    /// - Parameter mode: `.light`, `.dark`, or `nil` to follow the system.
    public static func forceAppearance(_ mode: SystemAppearanceName?) {
        if let mode {
            UserDefaults.standard.set(mode.rawValue, forKey: forceAppearanceKey)
            NSApp.appearance = (mode == .dark)
                ? NSAppearance(named: .darkAqua)
                : NSAppearance(named: .aqua)
        } else {
            UserDefaults.standard.removeObject(forKey: forceAppearanceKey)
            NSApp.appearance = nil // Follow system
        }

        NotificationCenter.default.post(
            name: .systemAppearanceDidChange,
            object: ThemeManager.shared
        )
    }
}

// MARK: - Private Observation

private extension ThemeManager {

    /// Begin KVO observation of `NSApp.effectiveAppearance`.
    ///
    /// When the system appearance changes (e.g., the user switches between
    /// light and dark mode in System Settings), we post a notification so all
    /// panels can recompute their chrome and content colors.
    func beginObservingAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self = self else { return }
            Task { @MainActor in
                // Only broadcast when the user has not set a forced override.
                // Forced appearance changes are posted via `forceAppearance(_:)`.
                if UserDefaults.standard.string(forKey: forceAppearanceKey) == nil {
                    NotificationCenter.default.post(
                        name: .systemAppearanceDidChange,
                        object: self
                    )
                }
            }
        }
    }
}
