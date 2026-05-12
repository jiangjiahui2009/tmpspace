import AppKit
import FlashboxSettings

func bootLog(_ msg: String) {
    guard let data = (msg + "\n").data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/flashbox-boot.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

bootLog("main.swift started")

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
bootLog("before AppDelegate init")
let delegate = AppDelegate()
bootLog("after AppDelegate init, delegate=\(delegate)")
app.delegate = delegate
bootLog("delegate set, before finishLaunching")
app.finishLaunching()
bootLog("finishLaunching returned")
app.run()
bootLog("run() returned – app terminating")
