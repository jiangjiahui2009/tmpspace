import AppKit

/// Shared constants used across all Tmpspace modules.
public enum Constants {
    /// Maximum number of concurrently open floating panels.
    public static let maxPanelCount = 5

    /// Default keyboard shortcut key for toggling panels.
    public static let defaultShortcutKey: String = "s"

    /// Default modifier flags raw value (option + shift = 655360).
    public static let defaultShortcutModifierRawValue: UInt = NSEvent.ModifierFlags([.option, .shift]).rawValue

    /// Default modifier flags for the global shortcut (option + shift).
    public static let defaultShortcutModifiers: NSEvent.ModifierFlags = [.option, .shift]

    /// Default keyboard shortcut key for quick copy (Finder files → editor).
    public static let defaultQuickCopyKey: String = "c"

    /// Default modifier flags raw value for quick copy (option + shift = 655360).
    public static let defaultQuickCopyModifierRawValue: UInt = NSEvent.ModifierFlags([.option, .shift]).rawValue

    /// Default modifier flags for the quick copy shortcut (option + shift).
    public static let defaultQuickCopyModifiers: NSEvent.ModifierFlags = [.option, .shift]

    /// Debounce interval (milliseconds) before auto-saving panel content.
    public static let autoSaveDebounceMs: UInt64 = 500

    /// Default panel width in points.
    public static let defaultPanelWidth: CGFloat = 320

    /// Default panel height in points.
    public static let defaultPanelHeight: CGFloat = 420

    /// Minimum panel width in points.
    public static let minPanelWidth: CGFloat = 200

    /// Minimum panel height in points.
    public static let minPanelHeight: CGFloat = 150

    /// App group identifier.
    public static let appGroupIdentifier = "com.tmpspace.app"

    /// Panel data storage filename (inside Application Support).
    public static let panelsStorageFilename = "panels.json"

    /// Encryption key label for the Keychain-stored key.
    public static let encryptionKeyLabel = "com.tmpspace.storage.encryption"
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the user selects "偏好设置..." from the menu bar.
    public static let tmpspaceOpenPreferences = Notification.Name("TmpspaceOpenPreferences")
    /// Posted when the user selects "新建编辑框" from the main menu (File > New).
    public static let tmpspaceMenuCreatePanel = Notification.Name("TmpspaceMenuCreatePanel")
}
