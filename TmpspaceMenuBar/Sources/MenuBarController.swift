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

    /// Syntax highlighting themes shown in the menu bar theme submenu.
    private static let availableThemes: [(id: String, label: String)] = [
        ("system",               "跟随系统"),
        ("github-light",         "GitHub Light"),
        ("github-dark",          "GitHub Dark"),
        ("xcode-light",          "Xcode Light"),
        ("xcode-dark",           "Xcode Dark"),
        ("dracula",              "Dracula"),
        ("cobalt",               "Cobalt"),
        ("winter-is-coming-light", "冬日渐近·浅"),
        ("winter-is-coming-dark",  "冬日渐近·深"),
        ("minimal-light",        "极简·浅"),
        ("minimal-dark",         "极简·深"),
        ("synthwave84",          "Synthwave '84"),
        ("night-owl",            "夜猫子"),
        ("rose-pine-dawn",       "松木玫瑰·晨"),
        ("rose-pine",            "松木玫瑰·夜"),
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
            title: "显示/隐藏",
            action: #selector(menuTogglePanels),
            keyEquivalent: currentShortcutKey
        )
        toggleItem.keyEquivalentModifierMask = currentShortcutModifiers
        toggleItem.target = self
        statusMenu.addItem(toggleItem)

        statusMenu.addItem(.separator())

        // ---- 新建 ----
        let newItem = NSMenuItem(
            title: "新建",
            action: #selector(menuCreatePanel),
            keyEquivalent: "n"
        )
        newItem.keyEquivalentModifierMask = .command
        newItem.target = self
        newItem.isEnabled = panelManager.panels.count < Constants.maxPanelCount
        statusMenu.addItem(newItem)

        statusMenu.addItem(.separator())

        // ---- Dynamic panel list ----
        for (index, panel) in panelManager.panels.enumerated() {
            let panelItem = NSMenuItem(
                title: "编辑框 \(index + 1)",
                action: nil,
                keyEquivalent: ""
            )
            panelItem.isEnabled = true

            let submenu = NSMenu(title: "")
            let deleteItem = NSMenuItem(
                title: "删除",
                action: #selector(menuDeletePanel(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = panel.id as UUID
            submenu.addItem(deleteItem)

            statusMenu.setSubmenu(submenu, for: panelItem)
            statusMenu.addItem(panelItem)
        }

        statusMenu.addItem(.separator())

        // ---- 偏好设置 ----
        let prefsItem = NSMenuItem(
            title: "偏好设置...",
            action: #selector(menuOpenPreferences),
            keyEquivalent: ""
        )
        prefsItem.target = self
        statusMenu.addItem(prefsItem)

        // ---- 颜色主题 ----
        let themeItem = NSMenuItem(
            title: "颜色主题",
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
            title: "窗口浮在最前",
            action: #selector(menuToggleAlwaysOnTop),
            keyEquivalent: ""
        )
        topItem.target = self
        topItem.state = alwaysOnTop ? .on : .off
        statusMenu.addItem(topItem)

        statusMenu.addItem(.separator())

        // ---- 退出 ----
        let quitItem = NSMenuItem(
            title: "退出",
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

        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.25
        button.layer?.add(transition, forKey: "iconTransition")

        let iconName: String
        let useTemplate: Bool
        if visible {
            var custom = UserDefaults.standard.string(forKey: "customMenuBarIcon") ?? "tmp"
            if custom == "random" {
                custom = Self.resolveRandomIcon()
            }
            iconName = "icon/\(custom)"
            useTemplate = (custom == "tmp")
        } else {
            iconName = "icon/tmp"
            useTemplate = true
        }
        button.image = useTemplate
            ? Self.loadTemplateImage(iconName)
            : (Self.loadColoredImage(iconName) ?? Self.loadTemplateImage("icon/tmp"))

        // Reposition the drop zone when the icon changes (the button frame may shift).
        positionDropZone()
    }

    /// Load a template image from the TmpspaceMenuBar resource bundle.
    /// Tries PNG first (sharper at small sizes), then falls back to SVG.
    public static func loadTemplateImage(_ name: String) -> NSImage? {
        let directory = (name as NSString).deletingLastPathComponent
        let baseName = (name as NSString).lastPathComponent

        for ext in ["png", "svg"] {
            guard let path = Bundle.module.path(forResource: baseName, ofType: ext, inDirectory: directory) else {
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

    /// Available custom icons for the menu bar (shown state).
    /// Each string is the base name (without extension), usable with `loadTemplateImage("icon/\\(name)")`.
    /// Icon IDs eligible for random selection (excludes tmp and random placeholder).
    private static let randomIconPool: [String] = [
        "Botany", "cat music", "chameleon", "coffeepot", "cup", "dog",
        "dolphin", "juice", "lion", "milk tea", "music", "orange cat",
        "outdoor", "owl", "penguin", "snake", "T-Rex", "wander", "water",
        "yawn-1", "yawn", "yellow cat",
    ]

    /// Resolve a "random" selection to a concrete icon ID.
    private static func resolveRandomIcon() -> String {
        randomIconPool.randomElement() ?? "tmp"
    }

    public static let availableIcons: [(id: String, label: String)] = [
        ("tmp",            "默认"),
        ("random",         "随机"),
        ("Botany",         "植物"),
        ("cat music",      "听歌猫"),
        ("chameleon",      "变色龙"),
        ("coffeepot",      "咖啡壶"),
        ("cup",            "杯子"),
        ("dog",            "狗"),
        ("dolphin",        "海豚"),
        ("juice",          "果汁"),
        ("lion",           "狮子"),
        ("milk tea",       "奶茶"),
        ("music",          "音乐"),
        ("orange cat",     "橘猫"),
        ("outdoor",        "户外"),
        ("owl",            "猫头鹰"),
        ("penguin",        "企鹅"),
        ("snake",          "蛇"),
        ("T-Rex",          "霸王龙"),
        ("wander",         "漫游"),
        ("water",          "水"),
        ("yawn-1",         "打哈欠 1"),
        ("yawn",           "打哈欠"),
        ("yellow cat",     "黄猫"),
    ]

    /// Load an icon image for preview (non-template, shows original colors).
    /// Falls back to template loading if the icon file doesn't exist.
    public static func loadPreviewImage(_ name: String) -> NSImage? {
        // Return the template image at a slightly larger size for preview.
        guard let image = loadTemplateImage(name) else { return nil }
        let copy = image.copy() as! NSImage
        copy.isTemplate = false
        copy.size = NSSize(width: 40, height: 40)
        return copy
    }
}
