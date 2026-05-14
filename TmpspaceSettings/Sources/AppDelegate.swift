//
//  AppDelegate.swift
//  TmpspaceSettings
//
//  Application lifecycle management for the Tmpspace menu bar app.
//  Handles launch, termination, reopen, and initializes global shortcuts.
//

import AppKit
import TmpspaceCore
import TmpspaceMenuBar
import TmpspaceEditor
import TmpspaceStorage

/// Posted when the application is about to terminate.
/// Storage modules should listen for this to flush pending writes.
extension Notification.Name {
    static let tmpspaceAppWillTerminate = Notification.Name("TmpspaceAppWillTerminate")
}

/// Application delegate managing the lifecycle of the Tmpspace menu bar app.
///
/// The app lives primarily in the menu bar (LSUIElement = true), with no Dock icon
/// or App Switcher presence. Regular `NSWindow` instances are opened for `.md`
/// document editing.
///
/// In the final TmpspaceApp executable, this class is the `@main` entry point.
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
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/tmpspace-boot.log")) {
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
        // falling back to the default defined in Constants.
        let savedKey = UserDefaults.standard.string(forKey: "globalShortcutKey") ?? Constants.defaultShortcutKey
        let savedModifiersRaw = UInt(
            UserDefaults.standard.integer(forKey: "globalShortcutModifiers")
        )
        let savedModifiers = NSEvent.ModifierFlags(rawValue: savedModifiersRaw)

        GlobalShortcutManager.shared.registerShortcut(
            key: savedKey,
            modifiers: savedModifiers
        )

        // ── Quick Copy shortcut (disabled) ──────────────────────
        // let savedQuickCopyKey = UserDefaults.standard.string(forKey: "quickCopyShortcutKey")
        //     ?? Constants.defaultQuickCopyKey
        // let savedQuickCopyModifiersRaw = UInt(
        //     UserDefaults.standard.integer(forKey: "quickCopyShortcutModifiers")
        // )
        // let savedQuickCopyModifiers = NSEvent.ModifierFlags(rawValue: savedQuickCopyModifiersRaw)
        //
        // GlobalShortcutManager.shared.registerQuickCopyShortcut(
        //     key: savedQuickCopyKey,
        //     modifiers: savedQuickCopyModifiers
        // )

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

        // ── Quick Copy shortcut re-registration (disabled) ──────
        // NotificationCenter.default.addObserver(
        //     forName: Notification.Name("GlobalQuickCopyShortcutDidChange"),
        //     object: nil,
        //     queue: .main
        // ) { [weak self] _ in
        //     Task { @MainActor [weak self] in
        //         self?.reregisterQuickCopyShortcut()
        //     }
        // }

        // Initialize the ThemeManager to begin observing appearance changes.
        _ = ThemeManager.shared

        // ── Bootstrap all modules ──────────────────────────────────
        let distPath = Bundle.main.path(forResource: "dist", ofType: nil)
            // Fallback during development:
            ?? NSString(string: "\(NSHomeDirectory())/Desktop/tmpspace/MarkEdit-main/CoreEditor/dist").expandingTildeInPath

        if let data = "distPath=\(distPath)\n".data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/tmpspace-boot.log")) {
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
                _ = try? data.write(to: URL(fileURLWithPath: "/tmp/tmpspace-boot.log"), options: .atomic)
            }
            fatalError("Failed to bootstrap Tmpspace: \(error)")
        }

        if let data = "AppBootstrap done, MenuBarController created\n".data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/tmpspace-boot.log")) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Notify storage modules to flush any pending writes.
        NotificationCenter.default.post(
            name: .tmpspaceAppWillTerminate,
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
            name: .tmpspaceShouldTogglePanels,
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
            "globalShortcutKey": Constants.defaultShortcutKey,
            "globalShortcutModifiers": Int(Constants.defaultShortcutModifierRawValue),
            "quickCopyShortcutKey": Constants.defaultQuickCopyKey,
            "quickCopyShortcutModifiers": Int(Constants.defaultQuickCopyModifierRawValue),
            "editorFontFamily": "system-ui",
            "editorFontSize": Double(14),
            "editorTheme": "system",
            "editorShowLineNumbers": false,
            "editorShowActiveLineIndicator": false,
            "editorLineHeight": Double(1.6),
            "editorTaskToggleSound": true,
            "editorReduceToolbarTransparency": false,
            "fileBoxFolderPath": "",
            "fileBoxMode": "copy",
            "menuBarDropZoneEnabled": false,
            "alwaysOnTop": true,
        ]
        UserDefaults.standard.register(defaults: defaults)
    }

    /// Re-register the global shortcut from the current UserDefaults values.
    private func reregisterGlobalShortcut() {
        let key = UserDefaults.standard.string(forKey: "globalShortcutKey") ?? Constants.defaultShortcutKey
        let modifiersRaw = UInt(
            UserDefaults.standard.integer(forKey: "globalShortcutModifiers")
        )
        let modifiers = NSEvent.ModifierFlags(rawValue: modifiersRaw)

        GlobalShortcutManager.shared.registerShortcut(key: key, modifiers: modifiers)
    }

    /// Re-register the quick copy shortcut from the current UserDefaults values.
    private func reregisterQuickCopyShortcut() {
        let key = UserDefaults.standard.string(forKey: "quickCopyShortcutKey") ?? Constants.defaultQuickCopyKey
        let modifiersRaw = UInt(
            UserDefaults.standard.integer(forKey: "quickCopyShortcutModifiers")
        )
        let modifiers = NSEvent.ModifierFlags(rawValue: modifiersRaw)

        GlobalShortcutManager.shared.registerQuickCopyShortcut(key: key, modifiers: modifiers)
    }
}

// MARK: - Notification Names (for Phase 2 wiring)

extension Notification.Name {
    /// Posted when the user requests toggling panels (via dock click or reopen).
    static let tmpspaceShouldTogglePanels = Notification.Name("TmpspaceShouldTogglePanels")
}
