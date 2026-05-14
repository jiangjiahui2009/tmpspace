# tmpspace

macOS 菜单栏浮动 Markdown 编辑器。SPM 项目，Swift 6，macOS 15+。

## 模块架构

| 模块 | 用途 |
|---|---|
| `TmpspaceApp/` | 可执行入口，main.swift + Info.plist |
| `TmpspaceCore/` | 共享模型：PanelModel, EditorDisplaySettings, Constants, protocols |
| `TmpspaceEditor/` | CodeMirror 6 via WKWebView (EditorViewController, EditorBridge) |
| `TmpspaceMenuBar/` | UI：MenuBarController, FloatingPanelController, PanelManager, FileBoxView |
| `TmpspaceSettings/` | 偏好设置 (SwiftUI), AppDelegate, GlobalShortcutManager |
| `TmpspaceStorage/` | 持久化：PanelStorage, AutoSaveManager, EncryptionService |

## 构建启动

```bash
cd TmpspaceApp
swift build
./.build/arm64-apple-macosx/debug/Tmpspace &
```

目录改名后 `.build/` 缓存会过期，需 `swift package clean`。

## 关键路径

- CoreEditor (vendored): `MarkEdit-main/CoreEditor/dist/`
- 配置回退: `~/Desktop/tmpspace/MarkEdit-main/CoreEditor/dist`
- App Support: `~/Library/Application Support/Tmpspace/`

## 已知坑点

- Info.plist 通过 linker flag `-sectcreate __TEXT __info_plist` 嵌入，路径是绝对路径，目录改名后要更新 Package.swift
- 菜单栏图标优先 PNG（`TmpspaceMenuBar/Sources/icon/tmp.svg`）
- CodeMirror `highlightSpecialChars()` 是静态扩展，用 WKUserScript 注入 CSS 覆盖 `.cm-specialChar`
- App 用 `NSApp.setActivationPolicy(.accessory)` 实现菜单栏模式

## 协作风格

- UI 中文，回复简洁，不加尾注和 emoji
- 快速迭代：改完就构建启动，少解释
