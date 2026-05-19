import AppKit
import TmpspaceCore

// MARK: - UserDefaults keys

private enum UserDefaultsKeys {
    static let panels = "com.tmpspace.panels"
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
            // Apply persisted display settings once editors have been swapped in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.applyCurrentSettingsToAll()
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
        // Observe editor display settings changes so all panels update live.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEditorDisplaySettingsDidChange),
            name: .editorDisplaySettingsDidChange,
            object: nil
        )
        // Observe "always on top" preference changes from Settings.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAlwaysOnTopDidChange),
            name: .tmpspaceAlwaysOnTopDidChange,
            object: nil
        )
        // Keep panel models in sync when individual panels are shown/hidden.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelsVisibilityChange),
            name: .tmpspacePanelsVisibilityDidChange,
            object: nil
        )
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

        NotificationCenter.default.post(
            name: .tmpspacePanelsVisibilityDidChange,
            object: self
        )
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
    /// Prompts for confirmation when the panel has content.
    public func deletePanel(id: UUID) {
        guard let controller = panelControllers[id] else { return }

        let content = editorProvider?.getContent(for: id) ?? panels.first(where: { $0.id == id })?.content ?? ""
        if !content.isEmpty {
            let alert = NSAlert()
            alert.messageText = Txt.str("确认删除")
            alert.informativeText = Txt.str("该编辑面板不为空，删除后内容将丢失。确定要删除吗？")
            alert.addButton(withTitle: Txt.str("删除"))
            alert.addButton(withTitle: Txt.str("取消"))
            alert.alertStyle = .warning
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
        }

        controller.closePanelCompletely()
        panelControllers.removeValue(forKey: id)
        panels.removeAll { $0.id == id }

        if panels.isEmpty {
            let model = makePanelModel()
            buildAndShowController(for: model)
        }

        persist()
    }

    // MARK: - Frontmost panel

    /// Returns the frontmost visible panel (highest `orderedIndex` among visible
    /// panel windows), or `nil` if no panels are currently visible.
    public func frontmostVisiblePanel() -> PanelModel? {
        let visible = panels.enumerated().compactMap { (index, panel) -> (Int, PanelModel)? in
            guard panel.isVisible, panelControllers[panel.id]?.window != nil else { return nil }
            return (index, panel)
        }
        guard !visible.isEmpty else { return nil }
        guard visible.count > 1 else { return visible.first?.1 }

        var best: PanelModel?
        var highest = Int.min
        for (_, panel) in visible {
            guard let window = panelControllers[panel.id]?.window else { continue }
            if window.orderedIndex > highest {
                highest = window.orderedIndex
                best = panel
            }
        }
        return best ?? visible.first?.1
    }

    /// Show panels if none are visible, then append text to the frontmost panel's
    /// content on a new line.
    public func quickCopyAppend(_ text: String) {
        guard !text.isEmpty else { return }

        if !panels.contains(where: { $0.isVisible }) {
            showPanels()
        }

        guard let frontmost = frontmostVisiblePanel(),
              let provider = editorProvider else { return }

        let current = provider.getContent(for: frontmost.id)
        let separator = (current.isEmpty || current.hasSuffix("\n")) ? "" : "\n"
        let newContent = current + separator + text

        provider.setContent(for: frontmost.id, content: newContent)

        // Bring the panel to the foreground
        if let controller = panelControllers[frontmost.id] {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Visibility

    /// Toggle a single panel's visibility by ID.
    /// Shows it if hidden, hides it if visible.
    public func togglePanelVisibility(id: UUID) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }

        if panels[index].isVisible {
            hidePanel(id: id)
        } else {
            showPanel(id: id)
        }
    }

    /// Show a single panel by ID.
    public func showPanel(id: UUID) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }

        if panelControllers[id] == nil {
            buildController(for: panels[index], at: index)
        }
        guard let controller = panelControllers[id] else { return }

        panels[index].isVisible = true
        controller.panelModel.isVisible = true
        applySavedFrame(to: controller, model: panels[index])
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.setActivationPolicy(.accessory)

        persist()
        NotificationCenter.default.post(
            name: .tmpspacePanelsVisibilityDidChange,
            object: self
        )
    }

    /// Hide a single panel by ID.
    public func hidePanel(id: UUID) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }

        if let window = panelControllers[id]?.window {
            panels[index].positionX = window.frame.origin.x
            panels[index].positionY = window.frame.origin.y
        }
        panels[index].isVisible = false
        panelControllers[id]?.panelModel.isVisible = false
        panelControllers[id]?.window?.orderOut(nil)

        persist()
        NotificationCenter.default.post(
            name: .tmpspacePanelsVisibilityDidChange,
            object: self
        )
    }

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
            controller.panelModel.isVisible = true
            applySavedFrame(to: controller, model: panels[index])
            controller.window?.orderFront(nil)
            DebugLog.log("ordered front, window=\(controller.window != nil ? "exists" : "nil")")
        }
        NotificationCenter.default.post(
            name: .tmpspacePanelsVisibilityDidChange,
            object: self
        )
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
            controller?.panelModel.isVisible = false
        }
        persist()
        NotificationCenter.default.post(
            name: .tmpspacePanelsVisibilityDidChange,
            object: self
        )
    }

    // MARK: - Always on top

    /// Update the "always on top" setting for all existing panels at runtime.
    func setAlwaysOnTop(_ alwaysOnTop: Bool) {
        for index in panels.indices {
            panels[index].alwaysOnTop = alwaysOnTop
            if let controller = panelControllers[panels[index].id] {
                controller.updateAlwaysOnTop(alwaysOnTop)
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

    // MARK: - Settings forwarding

    /// Apply the currently persisted `EditorDisplaySettings` to every open panel.
    private func applyCurrentSettingsToAll() {
        let settings = EditorDisplaySettings.load()
        // Update editor content display (font, theme, line numbers, etc.)
        if let provider = editorProvider {
            for panel in panels {
                provider.applySettings(settings, for: panel.id)
            }
        }
        // Update chrome (toolbar background, window appearance)
        for controller in panelControllers.values {
            controller.applyChromeFromSettings(settings)
        }
    }

    /// Notification handler for `.editorDisplaySettingsDidChange`.
    @objc private func handleEditorDisplaySettingsDidChange() {
        applyCurrentSettingsToAll()
    }

    /// Notification handler for `.tmpspaceAlwaysOnTopDidChange`.
    @objc private func handleAlwaysOnTopDidChange() {
        let alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        setAlwaysOnTop(alwaysOnTop)
    }

    /// Sync `isVisible` from live controllers after panels are individually
    /// shown/hidden (e.g. close button, miniaturize). Ensures `togglePanels()`
    /// sees the correct state on the next left-click.
    @objc private func handlePanelsVisibilityChange() {
        syncModelsFromControllers()
    }

    // MARK: - Private helpers

    private func makePanelModel() -> PanelModel {
        let at = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true
        let pos = initialPanelPosition(forWidth: Constants.defaultPanelWidth, height: Constants.defaultPanelHeight)
        let model = PanelModel(
            positionX: pos.x,
            positionY: pos.y,
            alwaysOnTop: at
        )
        panels.append(model)
        return model
    }

    /// Calculate the initial position for a new panel.
    /// - First panel: below the menu bar, near the right side of the screen.
    /// - Subsequent panels: cascaded diagonally from the previous panel.
    private func initialPanelPosition(forWidth w: CGFloat, height h: CGFloat) -> CGPoint {
        // If there is a previous panel with a known position, cascade from it.
        if let lastPos = panels.last?.position {
            let cascadeOffset: CGFloat = 24
            var newX = lastPos.x + cascadeOffset
            var newY = lastPos.y - cascadeOffset

            // If the cascaded position goes off-screen, wrap back to the
            // menu-bar-adjacent starting area.
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                if newX + w > visible.maxX || newY < visible.minY {
                    newX = visible.maxX - w - 20
                    newY = visible.maxY - h - 10
                }
            }
            return CGPoint(x: newX, y: newY)
        }

        // First panel: place it below the menu bar, near the right side.
        guard let screen = NSScreen.main else {
            return CGPoint(x: 200, y: 200)
        }
        let visible = screen.visibleFrame
        return CGPoint(
            x: visible.maxX - w - 20,
            y: visible.maxY - h - 10
        )
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
