import AppKit
import SwiftUI
import TmpspaceCore
import TmpspaceMenuBar
import TmpspaceEditor
import TmpspaceStorage

/// AppBootstrap wires together all Tmpspace modules.
///
/// It creates the concrete implementations, injects dependencies,
/// and connects callbacks between modules. Called once from AppDelegate
/// on app launch.
@MainActor
final class AppBootstrap: NSObject {

    // MARK: - Module instances

    let menuBarController: MenuBarController
    let editorProvider: EditorProviderProtocol
    let storage: PanelStorageProtocol

    // MARK: - Init

    /// - Parameter distPath: Absolute path to CoreEditor/dist/ containing
    ///   index.html and chunks/. Used by EditorViewController to load the JS editor.
    init(distPath: String) throws {
        // Helper to write boot log
        func blog(_ msg: String) {
            guard let data = (msg + "\n").data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: "/tmp/tmpspace-boot.log")
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }

        blog("AppBootstrap init — creating PanelStorage...")
        self.storage = try PanelStorage()
        blog("PanelStorage created OK")

        blog("AppBootstrap init — creating EditorViewController...")
        self.editorProvider = EditorViewController(distPath: distPath)
        blog("EditorViewController created OK")

        blog("AppBootstrap init — creating MenuBarController...")
        self.menuBarController = MenuBarController()
        blog("MenuBarController created OK")

        super.init()

        // Inject dependencies into PanelManager
        menuBarController.panelManager.editorProvider = editorProvider
        menuBarController.panelManager.storage = storage
        blog("Dependencies injected")

        // Show the initial panel now (synchronously, on the main thread,
        // during applicationDidFinishLaunching — the right time to activate).
        menuBarController.panelManager.showInitialPanel()
        blog("showInitialPanel done")

        // Wire persistent panels from storage
        Task { [weak self] in
            await self?.restorePanelsFromStorage()
        }

        // ── Global Shortcut ─────────────────────────────────────
        GlobalShortcutManager.shared.onShortcutPressed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.menuBarController.togglePanels()
            }
        }

        // ── Quick Copy Shortcut (disabled) ──────────────────────
        // GlobalShortcutManager.shared.onQuickCopyPressed = { [weak self] in
        //     Task { @MainActor [weak self] in
        //         self?.handleQuickCopy()
        //     }
        // }

        // ── Notifications ───────────────────────────────────────
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTogglePanels),
            name: .tmpspaceShouldTogglePanels,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: .tmpspaceAppWillTerminate,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenPreferences),
            name: .tmpspaceOpenPreferences,
            object: nil
        )

        blog("AppBootstrap init complete")
    }

    // MARK: - Storage restoration

    private func restorePanelsFromStorage() async {
        guard let panels = try? await storage.loadAllPanels(), !panels.isEmpty else {
            // No persisted panels — a default one was already created by PanelManager.init().
            return
        }

        // Remove the auto-created default panel(s) first.
        let existingIds = menuBarController.panelManager.panels.map { $0.id }
        for id in existingIds {
            menuBarController.panelManager.deletePanel(id: id)
        }

        for panel in panels {
            let model = menuBarController.panelManager.createPanel(from: panel)
            if !panel.content.isEmpty {
                editorProvider.setContent(for: model.id, content: panel.content)
            }
        }
    }

    // MARK: - Notification handlers

    @objc private func handleTogglePanels() {
        menuBarController.togglePanels()
    }

    /// Weak reference so we don't create duplicate windows.
    private weak var preferencesWindow: NSWindow?

    @objc private func handleOpenPreferences() {
        if let existing = preferencesWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let settingsView = SettingsView()
        let hosting = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Tmpspace 偏好设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // Set a fixed content size and position the window at the top
        // centre of the screen with a small margin from the menu bar.
        window.setContentSize(NSSize(width: 480, height: 520))
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let frame = window.frame
            let x = visible.midX - frame.width / 2
            let y = visible.maxY - frame.height - 40
            window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: frame.size), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        self.preferencesWindow = window
    }

    @objc private func handleAppWillTerminate() {
        Task {
            let models = menuBarController.panelManager.panels
            try? await storage.saveAllPanels(models)
        }
    }

    // MARK: - Quick Copy (disabled)

    // private func handleQuickCopy() { ... }
    // private static func readSelectedTextViaAccessibility() -> String? { ... }
    // private static func showAccessibilityPermissionPrompt() { ... }
    // private static func readPasteboardText(_ pb: NSPasteboard) -> String { ... }
}
