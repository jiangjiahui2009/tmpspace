import AppKit

/// Shared constants used across all Flashbox modules.
public enum Constants {
    /// Maximum number of concurrently open floating panels.
    public static let maxPanelCount = 5

    /// Default keyboard shortcut key for toggling panels.
    public static let defaultShortcutKey: String = " "

    /// Default modifier flags raw value (fn key = 8388608).
    public static let defaultShortcutModifierRawValue: UInt = NSEvent.ModifierFlags.function.rawValue

    /// Default modifier flags for the global shortcut (fn key).
    public static let defaultShortcutModifiers: NSEvent.ModifierFlags = .function

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
    public static let appGroupIdentifier = "com.flashbox.app"

    /// Panel data storage filename (inside Application Support).
    public static let panelsStorageFilename = "panels.json"

    /// Encryption key label for the Keychain-stored key.
    public static let encryptionKeyLabel = "com.flashbox.storage.encryption"
}
