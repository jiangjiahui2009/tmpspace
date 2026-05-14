import AppKit
import TmpspaceCore
import TmpspaceSettings

// Force Chinese localization for system dialogs (NSSavePanel, etc.).
// Must be set before NSApplication initializes.
UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")

func bootLog(_ msg: String) {
    guard let data = (msg + "\n").data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/tmpspace-boot.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

bootLog("main.swift started")

/// Lightweight action handler for main menu items that post notifications
/// instead of being routed through the MenuBarController (which may not exist yet).
@MainActor
private final class MenuActions: NSObject {
    @objc func openPreferences(_ sender: Any?) {
        NotificationCenter.default.post(name: .tmpspaceOpenPreferences, object: nil)
    }
    @objc func createPanel(_ sender: Any?) {
        NotificationCenter.default.post(name: .tmpspaceMenuCreatePanel, object: nil)
    }
}

// Observe the didFinishLaunching notification directly.
NotificationCenter.default.addObserver(
    forName: NSApplication.didFinishLaunchingNotification,
    object: nil,
    queue: .main
) { _ in
    bootLog("NSApplication.didFinishLaunchingNotification received!")
}

let app = NSApplication.shared
// Use .regular policy so windows can become key and accept input.
// LSUIElement=YES in Info.plist hides the Dock icon.
app.setActivationPolicy(.regular)

fileprivate let menuActions = MenuActions()

// Build a minimal main menu so that standard key equivalents
// (Cmd+V paste, Cmd+C copy, Cmd+X cut, Cmd+A select all, etc.)
// are routed through the responder chain to the WKWebView editor.
let mainMenu = NSMenu(title: "MainMenu")

// App menu
let appMenuItem = NSMenuItem(title: "Tmpspace", action: nil, keyEquivalent: "")
let appMenu = NSMenu(title: "Tmpspace")
appMenu.addItem(withTitle: "关于 Tmpspace", action: #selector(NSApp.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(.separator())
let prefsItem = appMenu.addItem(withTitle: "偏好设置...", action: #selector(menuActions.openPreferences(_:)), keyEquivalent: ",")
prefsItem.target = menuActions
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "退出 Tmpspace", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

// File menu
let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
let fileMenu = NSMenu(title: "File")
let newItem = fileMenu.addItem(withTitle: "新建编辑框", action: #selector(menuActions.createPanel(_:)), keyEquivalent: "n")
newItem.target = menuActions
fileMenu.addItem(.separator())
fileMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileMenuItem.submenu = fileMenu
mainMenu.addItem(fileMenuItem)

// Edit menu (critical: enables Cmd+V/C/X/A/Z etc. in WKWebView)
let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)

// Window menu
let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowMenuItem.submenu = windowMenu
mainMenu.addItem(windowMenuItem)

app.mainMenu = mainMenu

bootLog("before AppDelegate init")
let delegate = AppDelegate()
bootLog("after AppDelegate init, delegate=\(delegate)")
app.delegate = delegate
bootLog("delegate set, before finishLaunching")
app.finishLaunching()
bootLog("finishLaunching returned")
app.run()
bootLog("run() returned – app terminating")
