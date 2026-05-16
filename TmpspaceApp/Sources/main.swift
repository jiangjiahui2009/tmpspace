import AppKit

// When built by SPM (swift build), TmpspaceSettings is available as a linked
// module. When built by Xcode (which only compiles the stub for code signing),
// the module is absent — fall back to plain NSApplicationMain.
#if canImport(TmpspaceSettings)
import TmpspaceSettings

/// Lightweight target for menu items that post notifications instead of
/// routing through MenuBarController (which may not exist yet at startup).
private final class MenuActions: NSObject {
    @objc func openPreferences(_ sender: Any?) {
        NotificationCenter.default.post(name: .tmpspaceOpenPreferences, object: nil)
    }
    @objc func createPanel(_ sender: Any?) {
        NotificationCenter.default.post(name: .tmpspaceMenuCreatePanel, object: nil)
    }
}

private func buildMainMenu() -> NSMenu {
    let menuActions = MenuActions()
    let mainMenu = NSMenu(title: "MainMenu")

    // ── App menu ──
    let appMenuItem = NSMenuItem(title: "Tmpspace", action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: "Tmpspace")
    appMenu.addItem(withTitle: "关于 Tmpspace",
                    action: #selector(NSApp.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    let prefsItem = appMenu.addItem(withTitle: "偏好设置...",
                                     action: #selector(menuActions.openPreferences(_:)),
                                     keyEquivalent: ",")
    prefsItem.target = menuActions
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "退出 Tmpspace",
                    action: #selector(NSApp.terminate(_:)),
                    keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // ── File menu ──
    let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    let fileMenu = NSMenu(title: "File")
    let newItem = fileMenu.addItem(withTitle: "新建编辑框",
                                    action: #selector(menuActions.createPanel(_:)),
                                    keyEquivalent: "n")
    newItem.target = menuActions
    fileMenu.addItem(.separator())
    fileMenu.addItem(withTitle: "关闭",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    // ── Edit menu (critical: enables Cmd+V/C/X/A/Z in WKWebView) ──
    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "撤销",
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
    editMenu.addItem(withTitle: "重做",
                     action: Selector(("redo:")),
                     keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "剪切",
                     action: #selector(NSText.cut(_:)),
                     keyEquivalent: "x")
    editMenu.addItem(withTitle: "拷贝",
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴",
                     action: #selector(NSText.paste(_:)),
                     keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    // ── Window menu ──
    let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "最小化",
                       action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    return mainMenu
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.mainMenu = buildMainMenu()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#else
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
#endif
