//
//  AppDelegate.swift
//  FlashboxSettings
//
//  Application lifecycle management for the Flashbox menu bar app.
//  Handles launch, termination, reopen, and initializes global shortcuts.
//

import AppKit
import FlashboxCore
import FlashboxMenuBar
import FlashboxEditor
import FlashboxStorage

/// Posted when the application is about to terminate.
/// Storage modules should listen for this to flush pending writes.
extension Notification.Name {
    static let flashboxAppWillTerminate = Notification.Name("FlashboxAppWillTerminate")
}

/// Application delegate managing the lifecycle of the Flashbox menu bar app.
///
/// The app lives primarily in the menu bar (LSUIElement = true), with no Dock icon
/// or App Switcher presence. Regular `NSWindow` instances are opened for `.md`
/// document editing.
///
/// In the final FlashboxApp executable, this class is the `@main` entry point.
/// When the library is linked, the generated entry point creates `NSApplication.shared`,
/// sets this delegate, and calls `NSApp.run()`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The integration bootstrap — wires all modules together.
    private var bootstrap: AppBootstrap?

    // MARK: - NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Direct boot log (bypasses DebugLog which might have path issues).
        if let data = "applicationDidFinishLaunching called\n".data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/flashbox-boot.log")) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            }
        }

        // Ensure .regular at launch so the app can activate and windows become key.
        NSApp.setActivationPolicy(.regular)

        // Register default values for all UserDefaults keys used by SettingsView
        // and other modules. These take effect only when no value has been stored yet.
        registerDefaultUserDefaults()

        // Register the global hotkey using the persisted shortcut preference,
        // falling back to the default (fn+Space) defined in Constants.
        let savedKey = UserDefaults.standard.string(forKey: "globalShortcutKey") ?? " "
        let savedModifiersRaw = UInt(
            UserDefaults.standard.integer(forKey: "globalShortcutModifiers")
        )
        let savedModifiers = NSEvent.ModifierFlags(rawValue: savedModifiersRaw)

        GlobalShortcutManager.shared.registerShortcut(
            key: savedKey,
            modifiers: savedModifiers
        )

        // Re-register the shortcut when the user changes it in Settings.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("GlobalShortcutDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reregisterGlobalShortcut()
            }
        }

        // Initialize the ThemeManager to begin observing appearance changes.
        _ = ThemeManager.shared

        // ── Bootstrap all modules ──────────────────────────────────
        let distPath = Bundle.main.path(forResource: "dist", ofType: nil)
            // Fallback during development:
            ?? NSString(string: "\(NSHomeDirectory())/Desktop/Flashbox/MarkEdit-main/CoreEditor/dist").expandingTildeInPath

        if let data = "distPath=\(distPath)\n".data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/flashbox-boot.log")) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            }
        }

        do {
            bootstrap = try AppBootstrap(distPath: distPath)
        } catch {
            let msg = "AppBootstrap FAILED: \(error)\n"
            if let data = msg.data(using: .utf8) {
                _ = try? data.write(to: URL(fileURLWithPath: "/tmp/flashbox-boot.log"), options: .atomic)
            }
            fatalError("Failed to bootstrap Flashbox: \(error)")
        }

        if let data = "AppBootstrap done, MenuBarController created\n".data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/flashbox-boot.log")) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Notify storage modules to flush any pending writes.
        NotificationCenter.default.post(
            name: .flashboxAppWillTerminate,
            object: self
        )

        // Unregister the global hotkey so it does not linger after termination.
        GlobalShortcutManager.shared.unregisterCurrentShortcut()
    }

    /// Called when the user clicks the Dock icon (if LSUIElement were false)
    /// or when the app is reopened while already running.
    ///
    /// This toggles the panel visibility — in Phase 2 it will connect to
    /// `MenuBarManagerProtocol.togglePanels()`.
    public func applicationShouldHandleReopen(
        _ application: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // If no document windows are visible, toggle the floating panels.
        // In Phase 2, this calls menuBarManager.togglePanels().
        NotificationCenter.default.post(
            name: .flashboxShouldTogglePanels,
            object: self
        )
        return true
    }

    // MARK: - Private Helpers

    /// Register default values for all UserDefaults keys consumed by the app.
    ///
    /// `register(defaults:)` only sets values for keys that have not been
    /// explicitly stored yet, so it is safe to call on every launch.
    private func registerDefaultUserDefaults() {
        let defaults: [String: Any] = [
            "launchAtLogin": false,
            "defaultColorTheme": PanelColorTheme.system.rawValue,
            "defaultPanelWidth": Double(Constants.defaultPanelWidth),
            "defaultPanelHeight": Double(Constants.defaultPanelHeight),
            "globalShortcutKey": " ",
            "globalShortcutModifiers": Int(Constants.defaultShortcutModifierRawValue),
        ]
        UserDefaults.standard.register(defaults: defaults)
    }

    /// Re-register the global shortcut from the current UserDefaults values.
    private func reregisterGlobalShortcut() {
        let key = UserDefaults.standard.string(forKey: "globalShortcutKey") ?? " "
        let modifiersRaw = UInt(
            UserDefaults.standard.integer(forKey: "globalShortcutModifiers")
        )
        let modifiers = NSEvent.ModifierFlags(rawValue: modifiersRaw)

        GlobalShortcutManager.shared.registerShortcut(key: key, modifiers: modifiers)
    }
}

// MARK: - Notification Names (for Phase 2 wiring)

extension Notification.Name {
    /// Posted when the user requests toggling panels (via dock click or reopen).
    static let flashboxShouldTogglePanels = Notification.Name("FlashboxShouldTogglePanels")
}
