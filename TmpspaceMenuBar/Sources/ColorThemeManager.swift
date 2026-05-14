import AppKit
import TmpspaceCore

/// Singleton that manages the active color theme across all floating panels.
/// Posts a Notification when the theme changes so each panel can update its appearance.
@MainActor
final class ColorThemeManager {

    /// Shared singleton instance.
    static let shared = ColorThemeManager()

    /// The currently active theme applied to all panels.
    private(set) var currentTheme: PanelColorTheme = .system

    /// Notification posted when the global color theme changes.
    /// The `userInfo` dictionary contains:
    ///   - `"theme"`: the new `PanelColorTheme` raw value (String)
    static let themeDidChangeNotification = Notification.Name("ColorThemeManager.themeDidChange")

    private init() {}

    /// Set a new global theme and post a notification so every panel can react.
    func setTheme(_ theme: PanelColorTheme) {
        guard theme != currentTheme else { return }
        currentTheme = theme
        NotificationCenter.default.post(
            name: Self.themeDidChangeNotification,
            object: self,
            userInfo: ["theme": theme.rawValue]
        )
    }

    /// Apply a specific theme to a given floating panel controller.
    /// Sets the panel's chrome (toolbar area) background color and the window's
    /// visual appearance based on the theme.
    func applyTheme(_ theme: PanelColorTheme, to panelController: FloatingPanelController) {
        guard let window = panelController.window else { return }

        // Match the titlebar / chrome background to the theme colour.
        window.backgroundColor = theme.chromeColor

        // Apply the effective appearance so system controls follow light/dark.
        if let appearance = theme.effectiveAppearance {
            window.appearance = appearance
        } else {
            window.appearance = nil   // follow system
        }

        // Apply the chrome colour to the panel's custom toolbar area.
        panelController.applyToolbarBackground(theme.chromeColor)
    }
}
