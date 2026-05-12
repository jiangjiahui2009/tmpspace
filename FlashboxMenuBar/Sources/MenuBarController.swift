import AppKit
import FlashboxCore

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

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    // MARK: - Init

    public override init() {
        super.init()
        buildStatusItem()
        // Build the menu before assigning to statusItem.
        rebuildMenu()
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
        statusItem.menu = statusMenu
    }

    // MARK: - Status bar item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else {
            fatalError("NSStatusBar button is nil — cannot set up menu bar icon.")
        }

        button.image = NSImage(
            systemSymbolName: "square.and.pencil",
            accessibilityDescription: "Flashbox"
        )
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

        // ---- 显示/隐藏面板 ----
        let toggleItem = NSMenuItem(
            title: "显示/隐藏面板",
            action: #selector(menuTogglePanels),
            keyEquivalent: ""
        )
        toggleItem.target = self
        statusMenu.addItem(toggleItem)

        statusMenu.addItem(.separator())

        // ---- 新建编辑框 ----
        let newItem = NSMenuItem(
            title: "新建编辑框",
            action: #selector(menuCreatePanel),
            keyEquivalent: "N"
        )
        newItem.keyEquivalentModifierMask = .command
        newItem.target = self
        newItem.isEnabled = panelManager.panels.count < Constants.maxPanelCount
        statusMenu.addItem(newItem)

        statusMenu.addItem(.separator())

        // ---- 快捷键提示 ----
        let shortcutHint = NSMenuItem(
            title: "快捷键提示        fn+Space",
            action: nil,
            keyEquivalent: ""
        )
        shortcutHint.isEnabled = false
        statusMenu.addItem(shortcutHint)

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

        // ---- 颜色切换 ----
        let colorItem = NSMenuItem(
            title: "颜色切换",
            action: nil,
            keyEquivalent: ""
        )
        colorItem.isEnabled = true

        let colorMenu = NSMenu(title: "")
        for theme in PanelColorTheme.allCases {
            let themeItem = NSMenuItem(
                title: theme.displayName,
                action: #selector(menuSelectColorTheme(_:)),
                keyEquivalent: ""
            )
            themeItem.target = self
            themeItem.representedObject = theme
            themeItem.state = (theme == ColorThemeManager.shared.currentTheme) ? .on : .off
            colorMenu.addItem(themeItem)
        }
        statusMenu.setSubmenu(colorMenu, for: colorItem)
        statusMenu.addItem(colorItem)

        statusMenu.addItem(.separator())

        // ---- 退出 ----
        let quitItem = NSMenuItem(
            title: "退出 Flashbox",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    // MARK: - Menu actions

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

    @objc private func menuSelectColorTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? PanelColorTheme else { return }
        panelManager.applyThemeToAll(theme)
    }

    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }
}
