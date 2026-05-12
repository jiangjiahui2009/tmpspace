import AppKit
import FlashboxCore
import FlashboxMenuBar
import FlashboxEditor
import FlashboxStorage

/// AppBootstrap wires together all Flashbox modules.
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
            let url = URL(fileURLWithPath: "/tmp/flashbox-boot.log")
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

        // ── Notifications ───────────────────────────────────────
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTogglePanels),
            name: .flashboxShouldTogglePanels,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: .flashboxAppWillTerminate,
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

    @objc private func handleAppWillTerminate() {
        Task {
            let models = menuBarController.panelManager.panels
            try? await storage.saveAllPanels(models)
        }
    }
}
