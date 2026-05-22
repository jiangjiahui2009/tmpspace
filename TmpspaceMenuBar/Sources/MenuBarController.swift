import AppKit
import TmpspaceCore

/// Sets up the NSStatusBar icon and manages the right-click context menu.
///
/// Conforms to `MenuBarManagerProtocol` so external modules (like Settings /
/// the global shortcut manager) can drive panel visibility. Every protocol
/// method delegates to the internal `PanelManager`.
@MainActor
public final class MenuBarController: NSObject, MenuBarManagerProtocol, NSMenuDelegate {

    // MARK: - MenuBarManagerProtocol

    public var panels: [PanelModel] { panelManager.panels }
    public let isMenuBarReady: Bool = true

    public func togglePanels() { panelManager.togglePanels() }
    public func showPanels()   { panelManager.showPanels() }
    public func hidePanels()   { panelManager.hidePanels() }

    @discardableResult
    public func createNewPanel() -> PanelModel {
        panelManager.createNewPanel()
    }

    public func deletePanel(id: UUID) {
        panelManager.deletePanel(id: id)
    }

    // MARK: - Internal

    public let panelManager = PanelManager()

    /// Dedicated controller for the obsidian note panel (independent of the 5 regular panels).
    private var obsidianPanelController: FloatingPanelController?

    /// Tracked obsidian state for detecting setting changes.
    private var lastObsidianEnabled = false
    private var lastObsidianPath = ""

    /// Syntax highlighting themes shown in the menu bar theme submenu.
    private static let availableThemes: [(id: String, label: String)] = [
        ("system",               Txt.str("跟随系统")),
        ("github-light",         "GitHub Light"),
        ("github-dark",          "GitHub Dark"),
        ("xcode-light",          "Xcode Light"),
        ("xcode-dark",           "Xcode Dark"),
        ("dracula",              "Dracula"),
        ("cobalt",               "Cobalt"),
        ("winter-is-coming-light", Txt.str("冬日渐近·浅")),
        ("winter-is-coming-dark",  Txt.str("冬日渐近·深")),
        ("minimal-light",        Txt.str("极简·浅")),
        ("minimal-dark",         Txt.str("极简·深")),
        ("synthwave84",          "Synthwave '84"),
        ("night-owl",            Txt.str("夜猫子")),
        ("rose-pine-dawn",       Txt.str("松木玫瑰·晨")),
        ("rose-pine",            Txt.str("松木玫瑰·夜")),
        ("solarized-light",      "Solarized Light"),
        ("solarized-dark",       "Solarized Dark"),
    ]

    private var statusItem: NSStatusItem!
    private var dropZoneController: DropZoneController!
    private let statusMenu = NSMenu()

    // MARK: - Init

    public override init() {
        super.init()
        buildStatusItem()
        rebuildMenu()
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false

        // Observe panel visibility changes to animate the status bar icon.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelsVisibilityDidChange),
            name: .tmpspacePanelsVisibilityDidChange,
            object: nil
        )
        // Set initial icon state based on current panel visibility.
        updateStatusBarIcon(visible: panelManager.panels.contains { $0.isVisible })

        // Observe custom icon changes from Settings.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuBarIconDidChange),
            name: .tmpspaceMenuBarIconDidChange,
            object: nil
        )

        // Observe obsidian note settings — close panel when disabled or path cleared.
        lastObsidianEnabled = UserDefaults.standard.bool(forKey: "obsidianNoteEnabled")
        lastObsidianPath = UserDefaults.standard.string(forKey: "obsidianNotePath") ?? ""
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentEnabled = UserDefaults.standard.bool(forKey: "obsidianNoteEnabled")
                let currentPath = UserDefaults.standard.string(forKey: "obsidianNotePath") ?? ""
                let shouldClose = (self.lastObsidianEnabled && !currentEnabled)
                               || (!self.lastObsidianPath.isEmpty && currentPath.isEmpty)
                if shouldClose {
                    self.obsidianPanelController?.window?.orderOut(nil)
                    self.obsidianPanelController = nil
                }
                self.lastObsidianEnabled = currentEnabled
                self.lastObsidianPath = currentPath
            }
        }
    }

    // MARK: - Status bar item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else {
            return
        }

        let icon = Self.loadTemplateImage("icon/tmp")
        if let icon = icon {
            button.image = icon
        } else {
            button.title = "📝"
        }
        button.wantsLayer = true

        // Left-click toggles panels; right-click shows the menu.
        button.target = self
        button.action = #selector(handleStatusBarClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Create the drop zone controller. It positions its own panel
        // below the menu bar icon and catches file drags independently.
        dropZoneController = DropZoneController()
        dropZoneController.arePanelsVisible = { [weak self] in
            self?.panelManager.panels.contains { $0.isVisible } ?? false
        }
        positionDropZone()
        // Only enable if the user has toggled it on in Settings.
        let dropEnabled = UserDefaults.standard.bool(forKey: "menuBarDropZoneEnabled")
        if dropEnabled { dropZoneController.ensureVisible() }
        dropZoneController.setEnabled(dropEnabled)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDropZonePreferenceChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    /// Position the drop zone panel below the menu bar icon.
    private func positionDropZone() {
        guard let button = statusItem.button,
              let window = button.window else { return }
        let screenFrame = window.convertToScreen(button.bounds)
        dropZoneController.reposition(below: screenFrame)
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        DebugLog.log("menuNeedsUpdate called")
        rebuildMenu()
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        DebugLog.log("rebuildMenu — panels.count=\(panelManager.panels.count) max=\(Constants.maxPanelCount)")
        statusMenu.removeAllItems()

        // ---- 显示/隐藏 ----
        let toggleItem = NSMenuItem(
            title: Txt.str("显示/隐藏"),
            action: #selector(menuTogglePanels),
            keyEquivalent: currentShortcutKey
        )
        toggleItem.keyEquivalentModifierMask = currentShortcutModifiers
        toggleItem.target = self
        statusMenu.addItem(toggleItem)

        statusMenu.addItem(.separator())

        // ---- 新建 ----
        let newItem = NSMenuItem(
            title: Txt.str("新建"),
            action: #selector(menuCreatePanel),
            keyEquivalent: "n"
        )
        newItem.keyEquivalentModifierMask = .command
        newItem.target = self
        newItem.isEnabled = panelManager.panels.count < Constants.maxPanelCount
        statusMenu.addItem(newItem)

        statusMenu.addItem(.separator())

        // ---- 编辑面板 ----
        for (index, panel) in panelManager.panels.enumerated() {
            let panelItem = NSMenuItem(
                title: Txt.str("编辑面板 \(index + 1)"),
                action: #selector(menuTogglePanelVisibility(_:)),
                keyEquivalent: ""
            )
            panelItem.target = self
            panelItem.representedObject = panel.id as UUID
            panelItem.state = panel.isVisible ? .on : .off
            statusMenu.addItem(panelItem)
        }

        statusMenu.addItem(.separator())

        // ---- obsidian笔记 ----
        let obsidianEnabled = UserDefaults.standard.bool(forKey: "obsidianNoteEnabled")
        let obsidianPath = UserDefaults.standard.string(forKey: "obsidianNotePath") ?? ""
        let hasObsidianPath = obsidianEnabled && !obsidianPath.isEmpty && FileManager.default.fileExists(atPath: obsidianPath)
        let obsidianItem = NSMenuItem(
            title: Txt.str("obsidian笔记"),
            action: #selector(menuOpenObsidianNote),
            keyEquivalent: ""
        )
        obsidianItem.target = self
        obsidianItem.isEnabled = hasObsidianPath
        statusMenu.addItem(obsidianItem)

        statusMenu.addItem(.separator())

        // ---- 偏好设置 ----
        let prefsItem = NSMenuItem(
            title: Txt.str("偏好设置..."),
            action: #selector(menuOpenPreferences),
            keyEquivalent: ""
        )
        prefsItem.target = self
        statusMenu.addItem(prefsItem)

        // ---- 颜色主题 ----
        let themeItem = NSMenuItem(
            title: Txt.str("颜色主题"),
            action: nil,
            keyEquivalent: ""
        )
        let themeSubmenu = NSMenu(title: "")
        let currentTheme = UserDefaults.standard.string(forKey: "editorTheme") ?? "system"
        for (id, label) in Self.availableThemes {
            let item = NSMenuItem(
                title: label,
                action: #selector(menuSelectTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = id
            item.state = (id == currentTheme) ? .on : .off
            themeSubmenu.addItem(item)
        }
        statusMenu.setSubmenu(themeSubmenu, for: themeItem)
        statusMenu.addItem(themeItem)

        // ---- 窗口浮在最前 ----
        let alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        let topItem = NSMenuItem(
            title: Txt.str("窗口浮在最前"),
            action: #selector(menuToggleAlwaysOnTop),
            keyEquivalent: ""
        )
        topItem.target = self
        topItem.state = alwaysOnTop ? .on : .off
        statusMenu.addItem(topItem)

        statusMenu.addItem(.separator())

        // ---- 退出 ----
        let quitItem = NSMenuItem(
            title: Txt.str("退出"),
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    // MARK: - Menu actions

    /// Handle status bar button click: left-click toggles panels,
    /// right-click shows the context menu.
    @objc private func handleStatusBarClick() {
        guard let event = NSApp.currentEvent else {
            togglePanels()
            return
        }
        let isRightClick = event.type == .rightMouseUp || event.type == .rightMouseDown

        if isRightClick {
            rebuildMenu()
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanels()
        }
    }

    @objc private func menuTogglePanels() { togglePanels() }

    @objc private func menuCreatePanel() {
        DebugLog.log("menuCreatePanel called")
        panelManager.createNewPanel()
        DebugLog.log("menuCreatePanel done — panels.count=\(panelManager.panels.count)")
    }

    @objc private func menuDeletePanel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        panelManager.deletePanel(id: id)
    }

    @objc private func menuTogglePanelVisibility(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        panelManager.togglePanelVisibility(id: id)
    }

    @objc private func menuOpenObsidianNote() {
        guard UserDefaults.standard.bool(forKey: "obsidianNoteEnabled"),
              let path = UserDefaults.standard.string(forKey: "obsidianNotePath"),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }

        // If the obsidian panel already exists, just show it.
        if let controller = obsidianPanelController {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.setActivationPolicy(.accessory)
            return
        }

        // Create a dedicated panel model and controller for the obsidian note.
        let model = PanelModel()
        let controller = FloatingPanelController(panelModel: model)
        controller.panelManager = panelManager
        controller.editorProvider = panelManager.editorProvider
        controller.onCreateNewPanel = { [weak self] in
            _ = self?.panelManager.createNewPanel()
        }
        // Obsidian panel content lives in-memory only; no auto-save needed.

        let fileName = (path as NSString).lastPathComponent
        controller.setToolbarTitle(fileName)
        obsidianPanelController = controller
        controller.window?.makeKeyAndOrderFront(nil)

        // Load the .md file content after the editor is ready.
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.panelManager.editorProvider?.setContent(for: model.id, content: content)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func menuOpenPreferences() {
        NotificationCenter.default.post(name: .tmpspaceOpenPreferences, object: nil)
    }

    @objc private func menuSelectTheme(_ sender: NSMenuItem) {
        guard let themeId = sender.representedObject as? String else { return }
        UserDefaults.standard.set(themeId, forKey: "editorTheme")
        persistAndBroadcastEditorSettings()
    }

    @objc private func menuToggleAlwaysOnTop() {
        let current = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        UserDefaults.standard.set(!current, forKey: "alwaysOnTop")
        NotificationCenter.default.post(
            name: .tmpspaceAlwaysOnTopDidChange,
            object: nil
        )
    }

    /// Persist editor display settings from current UserDefaults and notify panels.
    private func persistAndBroadcastEditorSettings() {
        let fontFamily = UserDefaults.standard.string(forKey: "editorFontFamily") ?? "system-ui"
        let fontSize = UserDefaults.standard.double(forKey: "editorFontSize")
        let theme = UserDefaults.standard.string(forKey: "editorTheme") ?? "system"
        let showLineNumbers = UserDefaults.standard.bool(forKey: "editorShowLineNumbers")
        let showActiveLineIndicator = UserDefaults.standard.bool(forKey: "editorShowActiveLineIndicator")
        let lineHeight = UserDefaults.standard.double(forKey: "editorLineHeight")
        let taskToggleSound = UserDefaults.standard.bool(forKey: "editorTaskToggleSound")
        let reduceToolbarTransparency = UserDefaults.standard.bool(forKey: "editorReduceToolbarTransparency")

        let settings = EditorDisplaySettings(
            fontFamily: fontFamily,
            fontWeight: nil,
            fontStyle: nil,
            fontSize: fontSize,
            theme: theme,
            showLineNumbers: showLineNumbers,
            showActiveLineIndicator: showActiveLineIndicator,
            lineHeight: lineHeight,
            taskToggleSound: taskToggleSound,
            reduceToolbarTransparency: reduceToolbarTransparency
        )
        settings.save()
    }

    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func handleDropZonePreferenceChanged() {
        let enabled = UserDefaults.standard.bool(forKey: "menuBarDropZoneEnabled")
        dropZoneController.setEnabled(enabled)
        if enabled {
            positionDropZone()
            dropZoneController.ensureVisible()
        }
    }

    /// The current shortcut key character from UserDefaults.
    private var currentShortcutKey: String {
        UserDefaults.standard.string(forKey: "globalShortcutKey") ?? " "
    }

    /// The current shortcut modifiers from UserDefaults.
    private var currentShortcutModifiers: NSEvent.ModifierFlags {
        let raw = UInt(UserDefaults.standard.integer(forKey: "globalShortcutModifiers"))
        return NSEvent.ModifierFlags(rawValue: raw)
    }

    /// Build a human-readable shortcut string from stored UserDefaults values.
    private var currentShortcutDisplayString: String {
        let key = UserDefaults.standard.string(forKey: "globalShortcutKey") ?? " "
        let modifiersRaw = UInt(UserDefaults.standard.integer(forKey: "globalShortcutModifiers"))
        let modifiers = NSEvent.ModifierFlags(rawValue: modifiersRaw)
        var parts: [String] = []

        if modifiers.contains(.function) { parts.append("fn") }
        if modifiers.contains(.control)  { parts.append("\u{2303}") }
        if modifiers.contains(.option)   { parts.append("\u{2325}") }
        if modifiers.contains(.shift)    { parts.append("\u{21E7}") }
        if modifiers.contains(.command)  { parts.append("\u{2318}") }

        let keyDisplay = key.uppercased()
        parts.append(keyDisplay == " " ? "Space" : keyDisplay)

        return parts.joined(separator: " + ")
    }

    // MARK: - Status bar icon animation

    /// Called when panel visibility changes.
    @objc private func handlePanelsVisibilityDidChange() {
        let visible = panelManager.panels.contains { $0.isVisible }
        updateStatusBarIcon(visible: visible)
        positionDropZone()
        dropZoneController.ensureVisible()
    }

    /// Called when the user picks a different menu bar icon in Settings.
    @objc private func handleMenuBarIconDidChange() {
        let visible = panelManager.panels.contains { $0.isVisible }
        updateStatusBarIcon(visible: visible)
    }

    /// Update the status bar icon image based on panel visibility.
    /// - When panels are visible: custom icon (or show_state) selected by the user.
    /// - When hidden: always the default tmp icon.
    /// Uses a CATransition cross-fade for the icon change.
    private func updateStatusBarIcon(visible: Bool) {
        guard let button = statusItem.button else { return }

        let iconName: String
        let useTemplate: Bool
        if visible {
            var custom = UserDefaults.standard.string(forKey: "customMenuBarIcon") ?? "random"
            if custom == "random" {
                custom = Self.resolveRandomIcon()
            } else if custom.hasPrefix("random:") {
                let prefix = String(custom.dropFirst("random:".count))
                custom = Self.resolveRandomIcon(inCategory: prefix)
            }
            iconName = "icon/\(custom)"
            useTemplate = (custom == "tmp")
        } else {
            iconName = "icon/tmp"
            useTemplate = true
        }

        // Play bubble burst animation on icon switch.
        playIconSwitchAnimation(on: button)

        button.image = useTemplate
            ? Self.loadTemplateImage(iconName)
            : (Self.loadColoredImage(iconName) ?? Self.loadTemplateImage("icon/tmp"))

        // Reposition the drop zone when the icon changes (the button frame may shift).
        positionDropZone()
    }

    /// Play a bubble-burst particle animation on the status bar button.
    private func playIconSwitchAnimation(on button: NSStatusBarButton) {
        guard let layer = button.layer else { return }

        // Remove any previous emitter.
        layer.sublayers?.removeAll { $0 is CAEmitterLayer }

        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        emitter.emitterSize = CGSize(width: 4, height: 4)
        emitter.emitterShape = .point
        emitter.renderMode = .additive

        let bubbleImage = makeBubbleImage(size: 4).cgImage(forProposedRect: nil, context: nil, hints: nil)

        let cell = CAEmitterCell()
        cell.contents = bubbleImage
        cell.birthRate = 100
        cell.lifetime = 0.6
        cell.lifetimeRange = 0.2
        cell.velocity = 60
        cell.velocityRange = 40
        cell.emissionRange = .pi * 2
        cell.scale = 0.8
        cell.scaleRange = 0.4
        cell.scaleSpeed = -1.5
        cell.alphaSpeed = -2.0
        cell.color = NSColor.white.cgColor
        emitter.emitterCells = [cell]

        layer.addSublayer(emitter)

        // Burst: fire once then stop.
        emitter.birthRate = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            emitter.birthRate = 0
        }
        // Clean up after particles die.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            emitter.removeFromSuperlayer()
        }
    }

    /// Generate a small filled-circle image for the emitter cell.
    private func makeBubbleImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        return image
    }

    /// The bundle containing menu bar icon resources.
    /// In Xcode .app builds icons are in Bundle.main;
    /// in SPM dev builds they're in Bundle.module (the TmpspaceMenuBar module bundle).
    private static let resourceBundle: Bundle = {
        if Bundle.main.path(forResource: "tmp", ofType: "svg", inDirectory: "icon") != nil {
            return Bundle.main
        }
        return Bundle.module
    }()

    /// Load a template image from the TmpspaceMenuBar resource bundle.
    /// Tries PNG first (sharper at small sizes), then falls back to SVG.
    public static func loadTemplateImage(_ name: String) -> NSImage? {
        let directory = (name as NSString).deletingLastPathComponent
        let baseName = (name as NSString).lastPathComponent

        for ext in ["png", "svg"] {
            guard let path = resourceBundle.path(forResource: baseName, ofType: ext, inDirectory: directory) else {
                continue
            }

            if ext == "svg" {
                // SVG images are vector-based; pixelsWide/pixelsHigh return 0.
                // Load from data and force a point size suitable for menu bar (18pt).
                guard let svgData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let image = NSImage(data: svgData) else { continue }
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                return image
            } else {
                guard let image = NSImage(contentsOfFile: path) else { continue }
                let pixelWidth = image.representations.first?.pixelsWide ?? 36
                let pixelHeight = image.representations.first?.pixelsHigh ?? 36
                let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                image.size = NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
                image.isTemplate = true
                return image
            }
        }

        return nil
    }

    /// Load a colored (non-template) image for the menu bar.
    /// Preserves original SVG colors instead of rendering as a monochrome mask.
    public static func loadColoredImage(_ name: String) -> NSImage? {
        guard let image = loadTemplateImage(name) else { return nil }
        // Set isTemplate = false so macOS renders the original SVG colors.
        image.isTemplate = false
        return image
    }

    /// Available custom icons organized by category.
    /// Each icon ID includes the category prefix (e.g. "普通/cat music") for loading.
    public static let iconCategories: [(name: String, icons: [String])] = [
        (Txt.str("普通"), [
            "普通/cat music",
            "普通/chameleon",
            "普通/cup",
            "普通/dog",
            "普通/dolphin",
            "普通/music",
            "普通/owl",
            "普通/penguin",
            "普通/T-Rex",
        ]),
        (Txt.str("橙猫"), [
            "橙猫/Frame 33",
            "橙猫/Frame 34",
            "橙猫/Frame 35",
            "橙猫/Frame 36",
            "橙猫/Frame 37",
            "橙猫/Frame 38",
            "橙猫/Frame 39",
            "橙猫/Frame 40",
            "橙猫/Frame 41",
            "橙猫/Frame 42",
            "橙猫/orange cat",
        ]),
        (Txt.str("黑猫"), [
            "黑猫/Frame 59",
            "黑猫/Frame 60",
            "黑猫/Frame 61",
            "黑猫/Frame 62",
            "黑猫/Frame 63",
            "黑猫/Frame 64",
            "黑猫/Frame 65",
            "黑猫/Frame 66",
            "黑猫/Frame 67",
            "黑猫/Frame 68",
        ]),
        (Txt.str("黄猫"), [
            "黄猫/Frame 43",
            "黄猫/Frame 44",
            "黄猫/Frame 45",
            "黄猫/Frame 46",
            "黄猫/Frame 47",
            "黄猫/Frame 48",
            "黄猫/Frame 49",
            "黄猫/Frame 50",
            "黄猫/Frame 51",
            "黄猫/Frame 52",
            "黄猫/Frame 53",
            "黄猫/Frame 54",
            "黄猫/Frame 57",
        ]),
        (Txt.str("咖啡"), [
            "咖啡/Frame 20",
            "咖啡/Frame 21",
            "咖啡/Frame 22",
            "咖啡/Frame 23",
            "咖啡/Frame 24",
            "咖啡/Frame 25",
            "咖啡/Frame 26",
            "咖啡/Frame 27",
            "咖啡/Frame 28",
            "咖啡/Frame 29",
            "咖啡/Frame 30",
            "咖啡/Frame 31",
            "咖啡/Frame 32",
        ]),
        (Txt.str("稀有"), [
            "稀有/Botany",
            "稀有/juice",
            "稀有/lion",
            "稀有/milk tea",
            "稀有/outdoor",
            "稀有/snake",
            "稀有/wander",
            "稀有/yawn-1",
            "稀有/yawn",
            "稀有/yellow cat",
        ]),
    ]

    /// All custom icon IDs flattened for random selection.
    private static let randomIconPool: [String] = iconCategories.flatMap(\.icons)

    /// Resolve a "random" selection to a concrete icon ID (all categories).
    private static func resolveRandomIcon() -> String {
        randomIconPool.randomElement() ?? "tmp"
    }

    /// Resolve a random icon within a specific category (e.g. "橙猫").
    private static func resolveRandomIcon(inCategory prefix: String) -> String {
        iconCategories
            .flatMap(\.icons)
            .filter { $0.hasPrefix(prefix + "/") }
            .randomElement() ?? "tmp"
    }

    /// Load an icon image for preview (non-template, shows original colors).
    /// The `name` should include the full path under the icon directory,
    /// e.g. "icon/普通/cat music".
    public static func loadPreviewImage(_ name: String) -> NSImage? {
        guard let image = loadTemplateImage(name) else { return nil }
        let copy = image.copy() as! NSImage
        copy.isTemplate = false
        copy.size = NSSize(width: 40, height: 40)
        return copy
    }
}
