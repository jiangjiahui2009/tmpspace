import AppKit
import FlashboxCore

// MARK: - UserDefaults keys

private enum UserDefaultsKeys {
    static let panels = "com.flashbox.panels"
}

/// Manages the lifecycle of floating editor panels.
///
/// Responsibilities:
/// - Create / delete panels up to `Constants.maxPanelCount`.
/// - Show / hide / toggle all panels.
/// - Auto-create a new panel when the last one is deleted.
/// - Persist panel metadata to UserDefaults.
///
/// Conforms to `MenuBarManagerProtocol` so external modules can drive the menu bar.
@MainActor
public final class PanelManager: MenuBarManagerProtocol {

    // MARK: - MenuBarManagerProtocol

    /// The panel models currently being managed.
    public private(set) var panels: [PanelModel] = []

    /// Always `true` once this manager is initialised.
    public let isMenuBarReady: Bool = true

    // MARK: - Injected dependencies (set by AppBootstrap)

    /// Editor provider — when set, panels will swap the placeholder NSTextView
    /// for the real CodeMirror 6 editor.
    public var editorProvider: EditorProviderProtocol? {
        didSet {
            DebugLog.log("PanelManager.editorProvider didSet — provider=\(editorProvider != nil ? "exists" : "nil"), controllers=\(panelControllers.count)")
            guard let provider = editorProvider else { return }
            for controller in panelControllers.values {
                controller.editorProvider = provider
            }
        }
    }

    /// Storage provider — when set, panel CRUD and content changes are
    /// persisted through this service instead of UserDefaults.
    public var storage: PanelStorageProtocol?

    // MARK: - Internal state

    /// Floating window controllers keyed by panel ID.
    private var panelControllers: [UUID: FloatingPanelController] = [:]

    // MARK: - Init

    public init() {
        loadFromUserDefaults()
        // Ensure at least one panel exists (model only — the controller is
        // built later by showInitialPanel() called from AppBootstrap).
        if panels.isEmpty {
            _ = makePanelModel()
        }
    }

    /// Show the first panel — called synchronously from AppBootstrap after all
    /// dependencies (editorProvider, storage) have been injected.
    public func showInitialPanel() {
        guard let firstPanel = panels.first else { return }
        DebugLog.log("PanelManager — showInitialPanel for \(firstPanel.id)")
        let idx = panels.firstIndex(where: { $0.id == firstPanel.id }) ?? 0
        buildController(for: firstPanel, at: idx)
        guard let controller = panelControllers[firstPanel.id],
              let window = controller.window else {
            DebugLog.log("PanelManager — FAILED to get window")
            return
        }
        DebugLog.log("PanelManager — frame: \(NSStringFromRect(window.frame)), level: \(window.level.rawValue)")
        panels[0].isVisible = true
        applySavedFrame(to: controller, model: panels[0])
        DebugLog.log("PanelManager — canBecomeKey=\(window.canBecomeKey), isKeyBefore=\(window.isKeyWindow)")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugLog.log("PanelManager — after makeKeyAndOrderFront+activate, isKey=\(window.isKeyWindow), NSApp.isActive=\(NSApp.isActive)")

        // Now hide the Dock icon by switching to .accessory policy.
        // The window stays key even after the policy change.
        NSApp.setActivationPolicy(.accessory)
        DebugLog.log("PanelManager — after switching to accessory, isKey=\(window.isKeyWindow)")
    }

    // MARK: - Panel lifecycle

    /// Create a new panel model, build its window controller, and show it.
    @discardableResult
    public func createNewPanel() -> PanelModel {
        guard panels.count < Constants.maxPanelCount else {
            return panels[panels.count - 1]
        }

        let model = makePanelModel()
        buildAndShowController(for: model)
        persist()
        return model
    }

    /// Delete a panel by ID — closes its window and removes it from the array.
    /// If the last panel is deleted a fresh one is auto-created.
    public func deletePanel(id: UUID) {
        guard let controller = panelControllers[id] else { return }

        controller.closePanelCompletely()
        panelControllers.removeValue(forKey: id)
        panels.removeAll { $0.id == id }

        if panels.isEmpty {
            let model = makePanelModel()
            buildAndShowController(for: model)
        }

        persist()
    }

    // MARK: - Visibility

    public func togglePanels() {
        DebugLog.log("togglePanels — count=\(panels.count) visible=\(panels.map(\.isVisible))")
        if panels.contains(where: { $0.isVisible }) {
            hidePanels()
        } else {
            showPanels()
        }
    }

    public func showPanels() {
        DebugLog.log("showPanels — count=\(panels.count)")
        for index in panels.indices {
            let id = panels[index].id
            DebugLog.log("showing panel \(index): id=\(id)")
            if panelControllers[id] == nil {
                DebugLog.log("building controller...")
                buildController(for: panels[index], at: index)
            }
            guard let controller = panelControllers[id] else {
                DebugLog.log("ERROR: no controller for \(id)")
                continue
            }
            panels[index].isVisible = true
            applySavedFrame(to: controller, model: panels[index])
            controller.window?.orderFront(nil)
            DebugLog.log("ordered front, window=\(controller.window != nil ? "exists" : "nil")")
        }
    }

    public func hidePanels() {
        for index in panels.indices {
            let controller = panelControllers[panels[index].id]
            if let window = controller?.window {
                panels[index].positionX = window.frame.origin.x
                panels[index].positionY = window.frame.origin.y
                controller?.window?.orderOut(nil)
            }
            panels[index].isVisible = false
        }
        persist()
    }

    // MARK: - Theme

    /// Apply a new colour theme to every panel and persist the choice.
    func applyThemeToAll(_ theme: PanelColorTheme) {
        ColorThemeManager.shared.setTheme(theme)
        for index in panels.indices {
            panels[index].colorTheme = theme
            if let controller = panelControllers[panels[index].id] {
                ColorThemeManager.shared.applyTheme(theme, to: controller)
            }
        }
        persist()
    }

    // MARK: - Restore from storage

    /// Create a panel from a previously persisted model (used during app launch
    /// to restore saved panels). The panel is not shown by default.
    @discardableResult
    public func createPanel(from model: PanelModel) -> PanelModel {
        guard panels.count < Constants.maxPanelCount else {
            return panels[panels.count - 1]
        }
        var restored = model
        restored.isVisible = false
        panels.append(restored)
        persist()
        return restored
    }

    // MARK: - Content change forwarding

    private func handleContentChange(panelId: UUID, content: String) {
        if let idx = panels.firstIndex(where: { $0.id == panelId }) {
            panels[idx].content = content
            panels[idx].lastModifiedAt = Date()
        }
        guard let storage else {
            persist()  // fallback to UserDefaults
            return
        }
        Task {
            await storage.panelContentDidChange(id: panelId, content: content)
        }
    }

    // MARK: - Private helpers

    private func makePanelModel() -> PanelModel {
        let model = PanelModel()
        panels.append(model)
        return model
    }

    private func buildAndShowController(for model: PanelModel) {
        guard let index = panels.firstIndex(where: { $0.id == model.id }) else { return }
        buildController(for: model, at: index)
        guard let controller = panelControllers[model.id] else { return }
        applySavedFrame(to: controller, model: panels[index])
        panels[index].isVisible = true
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Re-hide Dock after activation.
        NSApp.setActivationPolicy(.accessory)
    }

    private func buildController(for model: PanelModel, at index: Int) {
        DebugLog.log("buildController — creating FloatingPanelController...")
        let controller = FloatingPanelController(panelModel: panels[index])
        DebugLog.log("buildController — FloatingPanelController created, window=\(controller.window != nil ? "exists" : "nil")")
        controller.panelManager = self
        controller.editorProvider = editorProvider
        controller.onCreateNewPanel = { [weak self] in
            _ = self?.createNewPanel()
        }
        controller.onContentChanged = { [weak self] panelId, content in
            self?.handleContentChange(panelId: panelId, content: content)
        }
        panelControllers[model.id] = controller
        DebugLog.log("buildController — done, controller stored")
    }

    /// Restore the panel's last-known position and size from its model.
    private func applySavedFrame(to controller: FloatingPanelController, model: PanelModel) {
        guard let window = controller.window, let position = model.position else {
            // If there is no saved position the controller already centres the window.
            return
        }
        window.setFrame(NSRect(origin: position, size: model.size), display: true)
    }

    // MARK: - Persistence (UserDefaults)

    /// Copy the latest frame / visibility data from the live controllers into the
    /// panels array and then write to UserDefaults.
    private func persist() {
        syncModelsFromControllers()
        guard let data = try? JSONEncoder().encode(panels) else { return }
        UserDefaults.standard.set(data, forKey: UserDefaultsKeys.panels)
    }

    private func loadFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.panels),
              let saved = try? JSONDecoder().decode([PanelModel].self, from: data)
        else { return }
        panels = saved
    }

    /// Pull the latest position, size, and visibility from each live controller
    /// so the `panels` array is always up-to-date before persisting.
    private func syncModelsFromControllers() {
        for index in panels.indices {
            let id = panels[index].id
            guard let controller = panelControllers[id] else { continue }
            panels[index].positionX = controller.panelModel.positionX
            panels[index].positionY = controller.panelModel.positionY
            panels[index].width = controller.panelModel.width
            panels[index].height = controller.panelModel.height
            panels[index].isVisible = controller.panelModel.isVisible
        }
    }
}
