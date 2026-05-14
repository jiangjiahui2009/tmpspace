//
//  SettingsView.swift
//  TmpspaceSettings
//
//  Preferences window content view with tabs for General and Shortcuts settings.
//

import SwiftUI
import TmpspaceCore
import ServiceManagement

/// The preferences window content view, providing Editor and General tabs.
@MainActor
public struct SettingsView: View {

    // MARK: - General Preferences

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("fileBoxFolderPath") private var fileBoxFolderPath = ""
    @AppStorage("fileBoxMode") private var fileBoxMode = "copy"
    @AppStorage("menuBarDropZoneEnabled") private var menuBarDropZoneEnabled = false

    // MARK: - Shortcut Preferences

    @AppStorage("globalShortcutKey") private var globalShortcutKey = " "
    @AppStorage("globalShortcutModifiers") private var globalShortcutModifiers = Int(Constants.defaultShortcutModifierRawValue)

    /// True while the shortcut recorder is listening for the next key press.
    @State private var isRecordingShortcut = false

    /// The local event monitor token used during shortcut recording.
    @State private var shortcutMonitor: Any?

    // MARK: - Editor display preferences

    @AppStorage("editorFontFamily") private var editorFontFamily = "system-ui"
    @AppStorage("editorFontSize") private var editorFontSize = Double(16)
    @AppStorage("editorTheme") private var editorTheme = "system"
    @AppStorage("editorShowLineNumbers") private var editorShowLineNumbers = true
    @AppStorage("editorShowActiveLineIndicator") private var editorShowActiveLineIndicator = false
    @AppStorage("editorLineHeight") private var editorLineHeight = Double(1.6)
    @AppStorage("editorTaskToggleSound") private var editorTaskToggleSound = true
    @AppStorage("editorReduceToolbarTransparency") private var editorReduceToolbarTransparency = true

    // MARK: - Quick Copy shortcut preferences (disabled)
    //
    // @AppStorage("quickCopyShortcutKey") private var quickCopyShortcutKey = Constants.defaultQuickCopyKey
    // @AppStorage("quickCopyShortcutModifiers") private var quickCopyShortcutModifiers = Int(Constants.defaultQuickCopyModifierRawValue)
    // @State private var isRecordingQuickCopy = false
    // @State private var quickCopyMonitor: Any?

    // MARK: - Body

    public var body: some View {
        TabView {
            editorTab
                .tabItem {
                    Label("编辑器", systemImage: "textformat.alt")
                }

            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }
        }
        .frame(minWidth: 460, minHeight: 320)
        .scenePadding()
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section {
                Toggle("窗口始终浮在最前", isOn: $alwaysOnTop)
                    .onChange(of: alwaysOnTop) { _, _ in
                        NotificationCenter.default.post(
                            name: .tmpspaceAlwaysOnTopDidChange,
                            object: nil
                        )
                    }
            } footer: {
                Text("开启后，tmpspace编辑面板将始终悬浮在其他窗口之上。")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        startShortcutRecording()
                    } label: {
                        HStack {
                            Image(systemName: "record.circle")
                                .foregroundStyle(isRecordingShortcut ? .red : .secondary)

                            Text(isRecordingShortcut ? "按下组合键…" : shortcutDisplayString)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(isRecordingShortcut ? .secondary : .primary)

                            Spacer()

                            if isRecordingShortcut {
                                Text("(Esc 取消)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isRecordingShortcut
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.1))
                                    : AnyShapeStyle(.quaternary))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRecordingShortcut)

                    HStack {
                        Button("恢复默认") {
                            resetShortcutToDefault()
                        }
                        .controlSize(.small)

                        Spacer()
                    }
                }
            } header: {
                Text("唤起快捷键")
            } footer: {
                Text("点击上方区域，然后按下你想要的组合键完成录制。")
            }

            // ── Quick Copy shortcut (disabled) ──────────────────
            // Section {
            //     VStack(alignment: .leading, spacing: 12) {
            //         Button { startQuickCopyRecording() } label: { ... }
            //         HStack { Button("恢复默认") { resetQuickCopyToDefault() } ... }
            //     }
            // } header: {
            //     Text("快速复制快捷键")
            // } footer: {
            //     Text("按下快捷键将 Finder 中选中的文件路径追加到编辑器末尾。")
            // }

            Section {
                HStack {
                    Text("文件夹")
                        .foregroundStyle(.secondary)
                    Text(fileBoxDisplayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Toggle("菜单栏拖拽存入", isOn: $menuBarDropZoneEnabled)
                    .help("编辑器隐藏时，拖拽文件到菜单栏图标即可存入临时空间。")

                Picker("拖拽模式", selection: $fileBoxMode) {
                    Text("复制").tag("copy")
                        .help("拖入和拖出均为复制，原文件保留。")
                    Text("移动").tag("move")
                        .help("拖入和拖出均为移动，原文件不保留。")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                HStack {
                    Button("打开文件夹") {
                        NSWorkspace.shared.open(fileBoxFolderURL)
                    }

                    Button("更改...") {
                        chooseFileBoxFolder()
                    }
                }
            } header: {
                Text("文件暂存")
            } footer: {
                Text("拖拽模式决定文件是复制还是移动到目标位置。")
            }

            Section {
                Toggle("开机自启", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        configureLaunchAtLogin(enabled: newValue)
                    }
            } footer: {
                Text("开启后，tmpspace将在登录时自动启动并在菜单栏中运行。")
            }

        }
        .formStyle(.grouped)
    }

    // MARK: - File Box helpers

    /// The current file box folder URL, expanding tilde if needed.
    private var fileBoxFolderURL: URL {
        let raw = fileBoxFolderPath
        let path = raw.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents")
                .appendingPathComponent("Tmpspace")
                .path
            : (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    /// Display-friendly abbreviated path.
    private var fileBoxDisplayPath: String {
        (fileBoxFolderURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Present an NSOpenPanel to choose a new file box folder.
    private func chooseFileBoxFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择文件盒子的存储文件夹"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileBoxFolderPath = url.path
    }

    // MARK: - Shortcut recording

    /// Begin listening for the next key-down event as the new shortcut.
    private func startShortcutRecording() {
        // Remove any existing monitor first.
        stopShortcutRecording(cancelled: true)

        isRecordingShortcut = true

        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            handleShortcutCapture(event)
            return nil // consume the event
        }
    }

    /// Stop the recording monitor and, if not cancelled, save the captured shortcut.
    private func stopShortcutRecording(cancelled: Bool) {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
        isRecordingShortcut = false
    }

    /// Process a captured key event when recording a new shortcut.
    private func handleShortcutCapture(_ event: NSEvent) {
        // Extract the key character (ignore Shift‑based casing for letters).
        let rawKey = event.charactersIgnoringModifiers ?? ""

        // Normalise: tab → "\t" stays "\t"; letters stay as-is;
        // space is " "; empty (modifier-only press) is ignored.
        let key: String
        if rawKey.isEmpty {
            stopShortcutRecording(cancelled: true)
            return
        }

        // Map common whitespace characters for storage consistency.
        switch rawKey {
        case "\u{0009}":       key = "\t"    // Tab
        case "\u{0003}":       key = "\r"    // Enter (⌤)
        case "\u{001B}":       stopShortcutRecording(cancelled: true); return // Escape → cancel
        default:               key = rawKey
        }

        // Capture modifiers held during the key press.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        stopShortcutRecording(cancelled: false)

        // Persist and broadcast.
        globalShortcutKey = key
        globalShortcutModifiers = Int(modifiers.rawValue)

        NotificationCenter.default.post(
            name: GlobalShortcutManager.shortcutDidChangeNotification,
            object: nil
        )
    }

    // MARK: - Quick Copy shortcut recording (disabled)
    //
    // private func startQuickCopyRecording() { ... }
    // private func stopQuickCopyRecording(cancelled: Bool) { ... }
    // private func handleQuickCopyCapture(_ event: NSEvent) { ... }

    // MARK: - Editor Tab

    /// Syntax highlighting theme names and their display labels.
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

    /// Editor font family choices.
    private static let fontFamilies: [(id: String, label: String)] = [
        ("system-ui", "系统字体"),
        ("SF Mono",   "SF Mono"),
        ("Menlo",      "Menlo"),
    ]

    @ViewBuilder
    private var editorTab: some View {
        Form {
            Section {
                Picker("语法高亮主题", selection: $editorTheme) {
                    ForEach(Self.availableThemes, id: \.id) { theme in
                        Text(theme.label).tag(theme.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: editorTheme) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Text("颜色主题")
            }

            Section {
                Picker("字体", selection: $editorFontFamily) {
                    ForEach(Self.fontFamilies, id: \.id) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .onChange(of: editorFontFamily) { _, _ in persistEditorDisplaySettings() }

                Stepper(value: $editorFontSize, in: 10...24, step: 1) {
                    HStack {
                        Text("字号:")
                        Text("\(Int(editorFontSize)) pt")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: editorFontSize) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Text("字体与字号")
            } footer: {
                Text("编辑器的显示字体和大小（10–24 点）。")
            }

            Section {
                Toggle("显示行号", isOn: $editorShowLineNumbers)
                    .onChange(of: editorShowLineNumbers) { _, _ in persistEditorDisplaySettings() }

                Toggle("显示当前行指示器", isOn: $editorShowActiveLineIndicator)
                    .onChange(of: editorShowActiveLineIndicator) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Text("辅助显示")
            }

            Section {
                Picker("行高", selection: $editorLineHeight) {
                    Text("紧凑").tag(1.4)
                    Text("正常").tag(1.6)
                    Text("宽松").tag(1.8)
                }
                .pickerStyle(.segmented)
                .onChange(of: editorLineHeight) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Text("行间距")
            }

            Section {
                Toggle("待办事项勾选音效", isOn: $editorTaskToggleSound)
                    .onChange(of: editorTaskToggleSound) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Text("音效")
            } footer: {
                Text("勾选待办事项时播放提示音。")
            }

            Section {
                Toggle("降低工具栏透明度", isOn: $editorReduceToolbarTransparency)
                    .onChange(of: editorReduceToolbarTransparency) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Text("工具栏外观")
            } footer: {
                Text("开启后工具栏使用不透明背景，关闭后使用半透明模糊效果。")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Display Helpers

    /// Build a human-readable string from the stored key and modifier flags.
    private var shortcutDisplayString: String {
        let modifiers: NSEvent.ModifierFlags = NSEvent.ModifierFlags(rawValue: UInt(globalShortcutModifiers))
        var parts: [String] = []

        if modifiers.contains(NSEvent.ModifierFlags.function)  { parts.append("fn") }
        if modifiers.contains(NSEvent.ModifierFlags.control)   { parts.append("\u{2303}") }   // ⌃
        if modifiers.contains(NSEvent.ModifierFlags.option)    { parts.append("\u{2325}") }   // ⌥
        if modifiers.contains(NSEvent.ModifierFlags.shift)     { parts.append("\u{21E7}") }   // ⇧
        if modifiers.contains(NSEvent.ModifierFlags.command)   { parts.append("\u{2318}") }   // ⌘

        let keyDisplay: String = {
            let k = globalShortcutKey.uppercased()
            switch k {
            case " ":  return "Space"
            case "\t": return "Tab"
            case "\r": return "Enter"
            default:   return k
            }
        }()
        parts.append(keyDisplay)

        return parts.joined(separator: " ")
    }

    // ── Quick Copy (disabled) ─────────────────────────────────
    //
    // private var quickCopyDisplayString: String { ... }

    // MARK: - Actions

    /// Reset the global shortcut to the default (Option+Space).
    private func resetShortcutToDefault() {
        globalShortcutKey = Constants.defaultShortcutKey
        globalShortcutModifiers = Int(Constants.defaultShortcutModifierRawValue)

        NotificationCenter.default.post(
            name: GlobalShortcutManager.shortcutDidChangeNotification,
            object: nil
        )
    }

    // ── Quick Copy (disabled) ─────────────────────────────────
    // private func resetQuickCopyToDefault() { ... }

    /// Persist the current editor display settings to UserDefaults and broadcast
    /// a notification so all open panels can apply the new values immediately.
    private func persistEditorDisplaySettings() {
        let settings = EditorDisplaySettings(
            fontFamily: editorFontFamily,
            fontWeight: nil,
            fontStyle: nil,
            fontSize: editorFontSize,
            theme: editorTheme,
            showLineNumbers: editorShowLineNumbers,
            showActiveLineIndicator: editorShowActiveLineIndicator,
            lineHeight: editorLineHeight,
            taskToggleSound: editorTaskToggleSound,
            reduceToolbarTransparency: editorReduceToolbarTransparency
        )
        settings.save()
    }

    /// Enable or disable launch at login using SMAppService (macOS 13+).
    private func configureLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // SMAppService may fail if not running as a bundled main app.
            // The preference is still persisted in UserDefaults for later use.
            NSLog(
                "[TmpspaceSettings] Failed to configure launch at login: %@",
                error.localizedDescription
            )
        }
    }
}
