//
//  SettingsView.swift
//  FlashboxSettings
//
//  Preferences window content view with tabs for General and Shortcuts settings.
//

import SwiftUI
import FlashboxCore
import ServiceManagement

/// The preferences window content view, providing General and Shortcuts tabs.
@MainActor
public struct SettingsView: View {

    // MARK: - General Preferences

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("defaultColorTheme") private var defaultColorTheme = PanelColorTheme.system.rawValue
    @AppStorage("defaultPanelWidth") private var defaultPanelWidth = Double(Constants.defaultPanelWidth)
    @AppStorage("defaultPanelHeight") private var defaultPanelHeight = Double(Constants.defaultPanelHeight)

    // MARK: - Shortcut Preferences

    @AppStorage("globalShortcutKey") private var globalShortcutKey = " "
    @AppStorage("globalShortcutModifiers") private var globalShortcutModifiers = Int(Constants.defaultShortcutModifierRawValue)

    // MARK: - Body

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            shortcutsTab
                .tabItem {
                    Label("快捷键", systemImage: "command")
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
                Toggle("开机自启", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        configureLaunchAtLogin(enabled: newValue)
                    }
            } footer: {
                Text("开启后，轻闪框将在登录时自动启动并在菜单栏中运行。")
            }

            Section {
                Picker("默认颜色主题", selection: $defaultColorTheme) {
                    ForEach(PanelColorTheme.allCases, id: \.rawValue) { theme in
                        Text(theme.displayName)
                            .tag(theme.rawValue)
                    }
                }
            } footer: {
                Text("新建面板时使用的颜色主题。")
            }

            Section {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("宽度:")
                        TextField("", value: $defaultPanelWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }

                    HStack(spacing: 4) {
                        Text("高度:")
                        TextField("", value: $defaultPanelHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }

                    Text("pt")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("默认面板大小")
            } footer: {
                Text("新建面板时的默认宽度和高度（单位：点）。")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts Tab

    @ViewBuilder
    private var shortcutsTab: some View {
        Form {
            Section {
                HStack {
                    Text("全局快捷键")

                    Spacer()

                    Text(shortcutDisplayString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                HStack {
                    Button("恢复默认") {
                        resetShortcutToDefault()
                    }
                    .controlSize(.small)

                    Spacer()
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text("使用全局快捷键快速显示或隐藏所有面板。\n修改快捷键后会自动重新注册。")
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

        let keyDisplay = globalShortcutKey.uppercased()
        // Replace space with a visible representation
        parts.append(keyDisplay == " " ? "Space" : keyDisplay)

        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    /// Reset the global shortcut to the default (fn+Space).
    private func resetShortcutToDefault() {
        globalShortcutKey = " "
        globalShortcutModifiers = Int(Constants.defaultShortcutModifierRawValue)

        NotificationCenter.default.post(
            name: GlobalShortcutManager.shortcutDidChangeNotification,
            object: nil
        )
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
                "[FlashboxSettings] Failed to configure launch at login: %@",
                error.localizedDescription
            )
        }
    }
}
