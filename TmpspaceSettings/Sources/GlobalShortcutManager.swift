//
//  GlobalShortcutManager.swift
//  TmpspaceSettings
//
//  Manages the global keyboard shortcut for toggling panels.
//  Uses Carbon Event HotKeys for standard modifiers and
//  NSEvent global monitor for shortcuts involving the fn key.
//

import AppKit
import Carbon.HIToolbox
import TmpspaceCore

private func tmpspaceHotKeyLog(_ msg: String) {
    guard let data = ("\(Date()) [HotKey] \(msg)\n").data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/tmpspace-debug.log")
    if let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
        try? h.close()
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when the registered global shortcut changes.
    static let globalShortcutDidChange = Notification.Name("GlobalShortcutDidChange")
    /// Posted when the quick copy shortcut changes.
    static let globalQuickCopyShortcutDidChange = Notification.Name("GlobalQuickCopyShortcutDidChange")
}

// MARK: - GlobalShortcutManager

/// Manages registration and unregistration of a global keyboard shortcut
/// that the user can press from anywhere to toggle Tmpspace panels.
@MainActor
public final class GlobalShortcutManager {

    // MARK: - Public Types

    /// Notification alias for external consumers.
    public static let shortcutDidChangeNotification = Notification.Name("GlobalShortcutDidChange")
    /// Notification alias for quick copy shortcut changes.
    public static let quickCopyShortcutDidChangeNotification = Notification.Name("GlobalQuickCopyShortcutDidChange")

    // MARK: - Shared Instance

    /// Shared singleton for app-wide access.
    public static let shared = GlobalShortcutManager()

    // MARK: - Callback

    /// Invoked when the registered global shortcut is pressed.
    /// Connected to `MenuBarManagerProtocol.togglePanels()` in Phase 2.
    public var onShortcutPressed: (() -> Void)?

    /// Invoked when the quick copy global shortcut is pressed.
    public var onQuickCopyPressed: (() -> Void)?

    // MARK: - Private State

    private var currentKey: String = " "
    private var currentModifiers: NSEvent.ModifierFlags = [.function]

    /// Carbon hotkey reference (nil when using NSEvent monitor or not registered).
    private var eventHotKeyRef: EventHotKeyRef?

    /// NSEvent global monitor token (nil when using Carbon or not registered).
    private var globalEventMonitor: Any?

    /// Quick copy shortcut state
    private var quickCopyKey: String = "c"
    private var quickCopyModifiers: NSEvent.ModifierFlags = [.option, .shift]
    private var quickCopyEventHotKeyRef: EventHotKeyRef?
    private var quickCopyGlobalEventMonitor: Any?

    /// Whether the Carbon event handler has been installed.
    private var carbonEventHandlerInstalled = false

    // MARK: - Init

    private init() {}

    // MARK: - Public Methods

    /// Register the default shortcut (fn+Space) as defined in `Constants`.
    public func registerDefaultShortcut() {
        registerShortcut(
            key: " ",
            modifiers: Constants.defaultShortcutModifiers
        )
    }

    /// Register a custom global shortcut with a key string and modifier flags.
    ///
    /// - Parameters:
    ///   - key: The key character (e.g., " " for Space, "A" for letter A).
    ///   - modifiers: `NSEvent.ModifierFlags` for the shortcut (e.g., `.function` for fn key).
    public func registerShortcut(key: String, modifiers: NSEvent.ModifierFlags) {
        tmpspaceHotKeyLog("registerShortcut called — key='\(key)' mods=\(modifiers.rawValue)")
        // Unregister any existing shortcut first
        unregisterCurrentShortcut()

        currentKey = key
        currentModifiers = modifiers

        // Determine which registration method to use:
        // - Carbon Event HotKey: for standard modifiers (cmd, shift, option, control).
        //   More reliable and does not require Accessibility permissions.
        // - NSEvent global monitor: for the fn key modifier, which Carbon does
        //   not natively support.
        if modifiers.contains(.function) {
            installGlobalEventMonitor(key: key, modifiers: modifiers)
        } else {
            registerCarbonHotKey(key: key, modifiers: modifiers)
        }
    }

    /// Register a custom quick copy global shortcut.
    ///
    /// - Parameters:
    ///   - key: The key character (e.g., "c" for letter C).
    ///   - modifiers: `NSEvent.ModifierFlags` for the shortcut.
    public func registerQuickCopyShortcut(key: String, modifiers: NSEvent.ModifierFlags) {
        tmpspaceHotKeyLog("registerQuickCopyShortcut called — key='\(key)' mods=\(modifiers.rawValue)")
        unregisterQuickCopyShortcut()

        quickCopyKey = key
        quickCopyModifiers = modifiers

        if modifiers.contains(.function) {
            installQuickCopyGlobalEventMonitor(key: key, modifiers: modifiers)
        } else {
            registerCarbonQuickCopyHotKey(key: key, modifiers: modifiers)
        }
    }

    /// Unregister the currently active shortcut, regardless of the underlying API.
    public func unregisterCurrentShortcut() {
        // Tear down Carbon hotkey
        if let ref = eventHotKeyRef {
            UnregisterEventHotKey(ref)
            eventHotKeyRef = nil
        }

        // Tear down NSEvent monitor
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }

        // Tear down quick copy shortcut
        unregisterQuickCopyShortcut()
    }

    /// Unregister the quick copy shortcut, regardless of the underlying API.
    public func unregisterQuickCopyShortcut() {
        if let ref = quickCopyEventHotKeyRef {
            UnregisterEventHotKey(ref)
            quickCopyEventHotKeyRef = nil
        }
        if let monitor = quickCopyGlobalEventMonitor {
            NSEvent.removeMonitor(monitor)
            quickCopyGlobalEventMonitor = nil
        }
    }

    // MARK: - Carbon HotKey Registration

    /// Register the shortcut using Carbon's `RegisterEventHotKey`.
    ///
    /// This method is preferred for shortcuts that use only standard modifiers
    /// (command, shift, option, control) because it reliably receives events
    /// without requiring Accessibility permissions.
    private func registerCarbonHotKey(key: String, modifiers: NSEvent.ModifierFlags) {
        guard let keyCode = virtualKeyCodes[key.uppercased()] else {
            NSLog("[TmpspaceSettings] Carbon: unknown key '%@'", key)
            fallbackToGlobalMonitor(key: key, modifiers: modifiers)
            return
        }

        let carbonMods = convertToCarbonModifiers(modifiers)
        let hotKeyID = EventHotKeyID(
            signature: GlobalShortcutManager.hotKeySignature,
            id: GlobalShortcutManager.hotKeyIDValue
        )

        var ref: EventHotKeyRef?
        let registerError = RegisterEventHotKey(
            keyCode,
            carbonMods,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard registerError == noErr, let hotKeyRef = ref else {
            NSLog(
                "[TmpspaceSettings] RegisterEventHotKey failed (err=%d), falling back to global monitor",
                registerError
            )
            fallbackToGlobalMonitor(key: key, modifiers: modifiers)
            return
        }

        eventHotKeyRef = hotKeyRef
        tmpspaceHotKeyLog("registerCarbonHotKey OK — key='\(key)' mods=\(modifiers.rawValue) carbonMods=\(carbonMods) keyCode=\(keyCode)")
        installCarbonEventHandler()
    }

    /// Install the Carbon event handler once for all hotkey events.
    private func installCarbonEventHandler() {
        guard !carbonEventHandlerInstalled else { return }
        guard let target = GetEventDispatcherTarget() else {
            NSLog("[TmpspaceSettings] GetEventDispatcherTarget returned nil")
            return
        }

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
        ]

        let installError = InstallEventHandler(
            target,
            GlobalShortcutManager.carbonEventCallback,
            eventTypes.count,
            eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &GlobalShortcutManager.eventHandlerRef
        )

        if installError == noErr {
            carbonEventHandlerInstalled = true
        } else {
            NSLog("[TmpspaceSettings] InstallEventHandler failed: %d", installError)
        }
    }

    /// Register the quick copy shortcut using Carbon's `RegisterEventHotKey`.
    private func registerCarbonQuickCopyHotKey(key: String, modifiers: NSEvent.ModifierFlags) {
        guard let keyCode = virtualKeyCodes[key.uppercased()] else {
            NSLog("[TmpspaceSettings] Carbon quick copy: unknown key '%@'", key)
            fallbackToQuickCopyGlobalMonitor(key: key, modifiers: modifiers)
            return
        }

        let carbonMods = convertToCarbonModifiers(modifiers)
        let hotKeyID = EventHotKeyID(
            signature: GlobalShortcutManager.hotKeySignature,
            id: GlobalShortcutManager.hotKeyIDValueCopy
        )

        var ref: EventHotKeyRef?
        let registerError = RegisterEventHotKey(
            keyCode,
            carbonMods,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        tmpspaceHotKeyLog("RegisterEventHotKey quick copy result: \(registerError == noErr ? "OK" : "err=\(registerError)")")
        guard registerError == noErr, let hotKeyRef = ref else {
            NSLog(
                "[TmpspaceSettings] RegisterEventHotKey quick copy failed (err=%d), falling back",
                registerError
            )
            fallbackToQuickCopyGlobalMonitor(key: key, modifiers: modifiers)
            return
        }

        quickCopyEventHotKeyRef = hotKeyRef
        installCarbonEventHandler() // already-installed guard prevents duplicate installs
    }

    // MARK: - NSEvent Global Monitor

    /// Use `NSEvent.addGlobalMonitorForEvents` as a fallback when Carbon cannot
    /// handle the modifier set (e.g., when the fn key is involved).
    ///
    /// - Note: This requires the app to have Accessibility permissions granted
    ///   in System Settings for global event monitoring to work.
    private func fallbackToGlobalMonitor(key: String, modifiers: NSEvent.ModifierFlags) {
        // Clean any partial Carbon registration state
        if let ref = eventHotKeyRef {
            UnregisterEventHotKey(ref)
            eventHotKeyRef = nil
        }
        installGlobalEventMonitor(key: key, modifiers: modifiers)
    }

    /// Install an NSEvent-based global key-down monitor.
    private func installGlobalEventMonitor(key: String, modifiers: NSEvent.ModifierFlags) {
        // Remove any existing monitor
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }

        let comparisonKey = key.uppercased()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }

            let eventKey = event.charactersIgnoringModifiers?.uppercased() ?? ""
            let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Compare the stored shortcut against the incoming key event
            if eventKey == comparisonKey && eventModifiers == modifiers {
                Task { @MainActor in
                    self.onShortcutPressed?()
                }
            }
        }
    }

    /// Fallback to NSEvent monitor when Carbon registration fails for quick copy.
    private func fallbackToQuickCopyGlobalMonitor(key: String, modifiers: NSEvent.ModifierFlags) {
        if let ref = quickCopyEventHotKeyRef {
            UnregisterEventHotKey(ref)
            quickCopyEventHotKeyRef = nil
        }
        installQuickCopyGlobalEventMonitor(key: key, modifiers: modifiers)
    }

    /// Install an NSEvent-based global key-down monitor for the quick copy shortcut.
    private func installQuickCopyGlobalEventMonitor(key: String, modifiers: NSEvent.ModifierFlags) {
        if let monitor = quickCopyGlobalEventMonitor {
            NSEvent.removeMonitor(monitor)
            quickCopyGlobalEventMonitor = nil
        }

        let comparisonKey = key.uppercased()

        quickCopyGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }

            let eventKey = event.charactersIgnoringModifiers?.uppercased() ?? ""
            let eventModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if eventKey == comparisonKey && eventModifiers == modifiers {
                Task { @MainActor in
                    self.onQuickCopyPressed?()
                }
            }
        }
    }

    // MARK: - Modifier Conversion

    /// Convert `NSEvent.ModifierFlags` to Carbon event modifier flags.
    private func convertToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        // CapsLock maps to alphaLock; exclude from typical shortcut modifiers
        if flags.contains(.shift)    { carbon |= UInt32(shiftKey) }
        if flags.contains(.control)  { carbon |= UInt32(controlKey) }
        if flags.contains(.option)   { carbon |= UInt32(optionKey) }
        if flags.contains(.command)  { carbon |= UInt32(cmdKey) }
        return carbon
    }

    // MARK: - Carbon Callback

    /// C function callback dispatched by Carbon when a registered hotkey fires.
    private static let carbonEventCallback: EventHandlerUPP = { _, event, userData in
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }

        guard Int(GetEventKind(event)) == kEventHotKeyPressed else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID()
        let error = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard error == noErr, hotKeyID.signature == hotKeySignature else {
            return OSStatus(eventNotHandledErr)
        }

        guard let userData else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()

        if hotKeyID.id == hotKeyIDValue {
            tmpspaceHotKeyLog("Carbon hotkey ID=1 (toggle) fired")
            Task { @MainActor in
                manager.onShortcutPressed?()
            }
        } else if hotKeyID.id == hotKeyIDValueCopy {
            tmpspaceHotKeyLog("Carbon hotkey ID=2 (quick copy) fired, callback=\(manager.onQuickCopyPressed != nil ? "set" : "nil")")
            Task { @MainActor in
                manager.onQuickCopyPressed?()
            }
        } else {
            tmpspaceHotKeyLog("Carbon hotkey UNKNOWN id=\(hotKeyID.id)")
        }

        return noErr
    }

    // MARK: - Carbon Static State

    /// Unique signature for Tmpspace hotkeys: "FBHK" (Tmpspace HotKey).
    private static let hotKeySignature: UInt32 = 0x4642484B

    /// HotKey ID for the currently registered shortcut.
    private static let hotKeyIDValue: UInt32 = 1

    /// HotKey ID for the quick copy shortcut.
    private static let hotKeyIDValueCopy: UInt32 = 2

    /// Carbon event handler reference, shared across hotkey registrations.
    private static var eventHandlerRef: EventHandlerRef?
}

// MARK: - Virtual Key Code Mapping

/// Mapping from key string to macOS virtual key codes (Carbon).
///
/// Based on: https://gist.github.com/eegrok/949034
private let virtualKeyCodes: [String: UInt32] = [
    // Letters
    "A": 0x00, "B": 0x0B, "C": 0x08, "D": 0x02, "E": 0x0E,
    "F": 0x03, "G": 0x05, "H": 0x04, "I": 0x22, "J": 0x26,
    "K": 0x28, "L": 0x25, "M": 0x2E, "N": 0x2D, "O": 0x1F,
    "P": 0x23, "Q": 0x0C, "R": 0x0F, "S": 0x01, "T": 0x11,
    "U": 0x20, "V": 0x09, "W": 0x0D, "X": 0x07, "Y": 0x10,
    "Z": 0x06,

    // Numbers
    "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
    "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,

    // Symbols
    " ": 0x31,  // kVK_Space
    "-": 0x1B, "=": 0x18,
    "[": 0x21, "]": 0x1E,
    "\\": 0x2A, ";": 0x29,
    "'": 0x27, ",": 0x2B,
    ".": 0x2F, "/": 0x2C,
    "`": 0x32,

    // Navigation / Whitespace
    "RETURN": 0x24, "TAB": 0x30,
    "SPACE": 0x31, "DELETE": 0x33,
    "ENTER": 0x34, "ESCAPE": 0x35,
    "HOME": 0x73, "END": 0x77,
    "PAGEUP": 0x74, "PAGEDOWN": 0x79,
    "LEFTARROW": 0x7B, "RIGHTARROW": 0x7C,
    "DOWNARROW": 0x7D, "UPARROW": 0x7E,
    "FORWARDDELETE": 0x75, "HELP": 0x72,

    // Modifiers (by themselves, rarely used as hotkey targets)
    "SHIFT": 0x38, "RIGHTSHIFT": 0x3C,
    "CAPSLOCK": 0x39,
    "OPTION": 0x3A, "RIGHTOPTION": 0x3D,
    "CONTROL": 0x3B, "RIGHTCONTROL": 0x3E,
    "FUNCTION": 0x3F,
    "COMMAND": 0x37, "RIGHTCOMMAND": 0x36,

    // Function keys
    "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76,
    "F5": 0x60, "F6": 0x61, "F7": 0x62, "F8": 0x64,
    "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
    "F13": 0x69, "F14": 0x6B, "F15": 0x71, "F16": 0x6A,
    "F17": 0x40, "F18": 0x4F, "F19": 0x50, "F20": 0x5A,

    // Keypad
    "KEYPAD0": 0x52, "KEYPAD1": 0x53, "KEYPAD2": 0x54,
    "KEYPAD3": 0x55, "KEYPAD4": 0x56, "KEYPAD5": 0x57,
    "KEYPAD6": 0x58, "KEYPAD7": 0x59, "KEYPAD8": 0x5B,
    "KEYPAD9": 0x5C, "KEYPADDECIMAL": 0x41,
    "KEYPADMULTIPLY": 0x43, "KEYPADPLUS": 0x45,
    "KEYPADCLEAR": 0x47, "KEYPADDIVIDE": 0x4B,
    "KEYPADENTER": 0x4C, "KEYPADMINUS": 0x4E,
    "KEYPADEQUALS": 0x51,
]
