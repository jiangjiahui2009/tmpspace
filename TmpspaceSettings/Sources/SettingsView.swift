//
//  SettingsView.swift
//  TmpspaceSettings
//
//  Preferences window content view with tabs for General and Shortcuts settings.
//

import SwiftUI
import TmpspaceCore
import TmpspaceMenuBar
import ServiceManagement

/// The preferences window content view, providing Editor and General tabs.
@MainActor
public struct SettingsView: View {

    // MARK: - General Preferences

    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("fileBoxFolderPath") private var fileBoxFolderPath = ""
    @AppStorage("fileBoxMode") private var fileBoxMode = "copy"
    @AppStorage("menuBarDropZoneEnabled") private var menuBarDropZoneEnabled = false
    @AppStorage("obsidianNotePath") private var obsidianNotePath = ""
    @AppStorage("obsidianNoteEnabled") private var obsidianNoteEnabled = false

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
    @AppStorage("customMenuBarIcon") private var customMenuBarIcon = "random"

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
                    Label(Txt.str("编辑器"), systemImage: "textformat.alt")
                }

            generalTab
                .tabItem {
                    Label(Txt.str("通用"), systemImage: "gearshape")
                }

            personalizationTab
                .tabItem {
                    Label(Txt.str("个性化"), systemImage: "paintpalette")
                }
        }
        .frame(minWidth: 460, minHeight: 320)
        .scenePadding()
        .onDisappear {
            // Clean up the shortcut recording monitor if the window is closed mid-record.
            stopShortcutRecording(cancelled: true)
        }
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section {
                Toggle(Txt.str("窗口始终浮在最前"), isOn: $alwaysOnTop)
                    .onChange(of: alwaysOnTop) { _, _ in
                        NotificationCenter.default.post(
                            name: .tmpspaceAlwaysOnTopDidChange,
                            object: nil
                        )
                    }
            } footer: {
                Txt.text("开启后，tmpspace编辑面板将始终悬浮在其他窗口之上。")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        startShortcutRecording()
                    } label: {
                        HStack {
                            Image(systemName: "record.circle")
                                .foregroundStyle(isRecordingShortcut ? .red : .secondary)

                            Text(isRecordingShortcut ? Txt.str("按下组合键…") : shortcutDisplayString)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(isRecordingShortcut ? .secondary : .primary)

                            Spacer()

                            if isRecordingShortcut {
                                Text(Txt.str("(Esc 取消)"))
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
                        Button(Txt.str("恢复默认")) {
                            resetShortcutToDefault()
                        }
                        .controlSize(.small)

                        Spacer()
                    }
                }
            } header: {
                Txt.text("唤起快捷键")
            } footer: {
                Txt.text("点击上方区域，然后按下你想要的组合键完成录制。")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("⌘ ;")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 52, alignment: .leading)
                        Txt.text("快速移动文件")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Text("⌘ L")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 52, alignment: .leading)
                        Txt.text("转为待办事项")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Txt.text("功能快捷键")
            } footer: {
                Txt.text("以下快捷键为系统内置，不可修改。Cmd+; 将 Finder 选中的文件移动到临时空间；Cmd+L 将选中的文本转换为待办事项列表。")
            }

            Section {
                HStack {
                    Txt.text("文件夹")
                        .foregroundStyle(.secondary)
                    Text(fileBoxDisplayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Toggle(Txt.str("菜单栏拖拽存入"), isOn: $menuBarDropZoneEnabled)
                    .help(Txt.str("编辑器隐藏时，拖拽文件到菜单栏图标即可存入临时空间。"))

                Picker(Txt.str("拖拽模式"), selection: $fileBoxMode) {
                    Txt.text("复制").tag("copy")
                        .help(Txt.str("拖入和拖出均为复制，原文件保留。"))
                    Txt.text("移动").tag("move")
                        .help(Txt.str("拖入和拖出均为移动，原文件不保留。"))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                HStack {
                    Button(Txt.str("打开文件夹")) {
                        NSWorkspace.shared.open(fileBoxFolderURL)
                    }

                    Button(Txt.str("更改...")) {
                        chooseFileBoxFolder()
                    }
                }
            } header: {
                Txt.text("文件暂存")
            } footer: {
                Txt.text("拖拽模式决定文件是复制还是移动到目标位置。")
            }

            Section {
                Toggle(Txt.str("启用obsidian笔记"), isOn: $obsidianNoteEnabled)

                if obsidianNoteEnabled {
                    HStack {
                        Txt.text("笔记路径")
                            .foregroundStyle(.secondary)
                        Text(obsidianNoteDisplayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(obsidianNotePath.isEmpty ? .tertiary : .primary)
                    }

                    Button(Txt.str("选择...")) {
                        chooseObsidianNoteFile()
                    }
                }
            } header: {
                Txt.text("obsidian笔记")
            } footer: {
                Txt.text("选择一个 .md 文件笔记，配置后可被快捷打开与编辑。")
            }

            Section {
                Toggle(Txt.str("开机自启"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        configureLaunchAtLogin(enabled: newValue)
                    }
            } footer: {
                Txt.text("开启后，tmpspace将在登录时自动启动并在菜单栏中运行。")
            }

        }
        .formStyle(.grouped)
    }

    // MARK: - Personalization Tab

    /// Grid layout for icon picker.
    private let iconGridColumns: [GridItem] = [
        .init(.adaptive(minimum: 56, maximum: 64), spacing: 8)
    ]

    @ViewBuilder
    private var personalizationTab: some View {
        Form {
            Section {
                LazyVGrid(columns: iconGridColumns, spacing: 10) {
                    specialIconCell(id: "tmp", label: Txt.str("默认"))
                    specialIconCell(id: "random", label: Txt.str("随机"), systemImage: "dice")
                }
                .padding(.vertical, 6)
            } header: {
                Txt.text("开箱图标")
            } footer: {
                Txt.text("选择编辑器显示时菜单栏的图标。隐藏状态下始终使用默认图标。")
            }

            ForEach(MenuBarController.iconCategories, id: \.name) { category in
                Section {
                    LazyVGrid(columns: iconGridColumns, spacing: 8) {
                        categoryRandomCell(for: category)
                        ForEach(category.icons, id: \.self) { iconId in
                            categoryIconCell(for: iconId)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text(category.name)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Special icon cell with label (for default and random).
    @ViewBuilder
    private func specialIconCell(id: String, label: String, systemImage: String? = nil) -> some View {
        let isSelected = customMenuBarIcon == id

        VStack(spacing: 4) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 26))
                        .foregroundStyle(isSelected ? .blue : .secondary)
                } else if let image = MenuBarController.loadPreviewImage("icon/\(id)") {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "questionmark.square")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            )

            Text(label)
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 64)
        .onTapGesture {
            customMenuBarIcon = id
            NotificationCenter.default.post(
                name: .tmpspaceMenuBarIconDidChange,
                object: nil
            )
        }
    }

    /// Random icon cell for a category — picks a random icon from that category.
    @ViewBuilder
    private func categoryRandomCell(for category: (name: String, icons: [String])) -> some View {
        let prefix = category.icons.first?.components(separatedBy: "/").first ?? ""
        let randomId = "random:\(prefix)"
        let isSelected = customMenuBarIcon == randomId

        VStack(spacing: 4) {
            Image(systemName: "dice")
                .font(.system(size: 26))
                .foregroundStyle(isSelected ? .blue : .secondary)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 2 : 1
                        )
                )

            Text(Txt.str("随机"))
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 64)
        .onTapGesture {
            customMenuBarIcon = randomId
            NotificationCenter.default.post(
                name: .tmpspaceMenuBarIconDidChange,
                object: nil
            )
        }
    }

    /// Category icon cell without label (icon only).
    @ViewBuilder
    private func categoryIconCell(for iconId: String) -> some View {
        let isSelected = customMenuBarIcon == iconId

        Group {
            if let image = MenuBarController.loadPreviewImage("icon/\(iconId)") {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "questionmark.square")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .frame(width: 64)
        .onTapGesture {
            customMenuBarIcon = iconId
            NotificationCenter.default.post(
                name: .tmpspaceMenuBarIconDidChange,
                object: nil
            )
        }
    }

    // MARK: - File Box helpers

    /// The current file box folder URL, resolved via FileBoxManager (handles sandbox).
    private var fileBoxFolderURL: URL {
        FileBoxManager.resolveFolderURL()
    }

    /// Display-friendly abbreviated path.
    private var fileBoxDisplayPath: String {
        (fileBoxFolderURL.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Obsidian Note helpers

    /// Display-friendly path for the obsidian note.
    private var obsidianNoteDisplayPath: String {
        if obsidianNotePath.isEmpty { return Txt.str("未配置") }
        return (obsidianNotePath as NSString).abbreviatingWithTildeInPath
    }

    /// Present an NSOpenPanel to choose a .md file for the obsidian note.
    private func chooseObsidianNoteFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = Txt.str("选择一个 Markdown 文件作为常驻笔记")
        panel.prompt = Txt.str("选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        obsidianNotePath = url.path
    }

    /// Present an NSOpenPanel to choose a new file box folder.
    private func chooseFileBoxFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = Txt.str("选择文件盒子的存储文件夹")
        panel.prompt = Txt.str("选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileBoxManager.saveBookmark(for: url)
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

    /// Editor font family choices.
    private static let fontFamilies: [(id: String, label: String)] = [
        ("system-ui", Txt.str("系统字体")),
        ("SF Mono",   "SF Mono"),
        ("Menlo",      "Menlo"),
    ]

    @ViewBuilder
    private var editorTab: some View {
        Form {
            Section {
                Picker(Txt.str("语法高亮主题"), selection: $editorTheme) {
                    ForEach(Self.availableThemes, id: \.id) { theme in
                        Text(theme.label).tag(theme.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: editorTheme) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Txt.text("颜色主题")
            }

            Section {
                Picker(Txt.str("字体"), selection: $editorFontFamily) {
                    ForEach(Self.fontFamilies, id: \.id) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .onChange(of: editorFontFamily) { _, _ in persistEditorDisplaySettings() }

                Stepper(value: $editorFontSize, in: 10...24, step: 1) {
                    HStack {
                        Txt.text("字号:")
                        Text("\(Int(editorFontSize)) pt")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: editorFontSize) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Txt.text("字体与字号")
            } footer: {
                Txt.text("编辑器的显示字体和大小（10–24 点）。")
            }

            Section {
                Toggle(Txt.str("显示行号"), isOn: $editorShowLineNumbers)
                    .onChange(of: editorShowLineNumbers) { _, _ in persistEditorDisplaySettings() }

                Toggle(Txt.str("显示当前行指示器"), isOn: $editorShowActiveLineIndicator)
                    .onChange(of: editorShowActiveLineIndicator) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Txt.text("辅助显示")
            }

            Section {
                Picker(Txt.str("行高"), selection: $editorLineHeight) {
                    Txt.text("紧凑").tag(1.4)
                    Txt.text("正常").tag(1.6)
                    Txt.text("宽松").tag(1.8)
                }
                .pickerStyle(.segmented)
                .onChange(of: editorLineHeight) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Txt.text("行间距")
            }

            Section {
                Toggle(Txt.str("待办事项勾选音效"), isOn: $editorTaskToggleSound)
                    .onChange(of: editorTaskToggleSound) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Txt.text("音效")
            } footer: {
                Txt.text("勾选待办事项时播放提示音。")
            }

            Section {
                Toggle(Txt.str("降低工具栏透明度"), isOn: $editorReduceToolbarTransparency)
                    .onChange(of: editorReduceToolbarTransparency) { _, _ in persistEditorDisplaySettings() }
            } header: {
                Txt.text("工具栏外观")
            } footer: {
                Txt.text("开启后工具栏使用不透明背景，关闭后使用半透明模糊效果。")
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
