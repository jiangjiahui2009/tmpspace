# tmpspace

macOS 菜单栏浮动 Markdown 编辑器。SPM 项目，Swift 6，macOS 15+。当前基线 v1.6.2。

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

## v1.4 新增

- **面板独立显隐**：右键菜单「编辑面板 X」点击切换显示/隐藏（对号标记）。`PanelManager.togglePanelVisibility(id:)`。
- **删除确认**：面板有内容时删除弹出二次确认。`PanelManager.deletePanel(id:)` 内检查 `editorProvider?.getContent(for:)`。
- **obsidian 笔记**：偏好配置 .md 路径后，右键菜单「obsidian笔记」打开独立编辑面板（不占用5个常规面板名额）。面板关闭保留编辑状态，偏好关闭开关或清空路径自动关闭面板。工具栏显示文件名。
  - 追踪：`MenuBarController.obsidianPanelController`（独立于 `PanelManager.panels`）
  - 偏好 key：`obsidianNoteEnabled`（Bool 开关）、`obsidianNotePath`（String 路径）

## v1.5 新增

- **菜单栏图标动画**：显示/隐藏切换时白色粒子爆发效果，`birthRate=100`。
- **图标分类**：自定义图标按 6 个分类展示（普通/橙猫/黑猫/黄猫/咖啡/稀有），默认图标改为随机。

## v1.6 新增

- **i18n 国际化**：根据系统语言自动切换中文/英文。使用 `String(localized:)` + `.xcstrings`。辅助方法 `Txt.str()` / `Txt.text()` 在 `TmpspaceCore/Sources/Txt.swift`，翻译在 `TmpspaceCore/Sources/Resources/Localizable.xcstrings`。

## v1.6.1 新增

- **分类随机图标**：每个图标分类最前面加随机骰子按钮，选中后该类别内随机选择图标。
- **偏好快捷键展示**：偏好设置中显示 Cmd+;（快速移动）和 Cmd+L（Todo）快捷键（只读）。
- **启动默认开启**：launchAtLogin 默认值改为 true。

## v1.6.2 修复

- **App Store 合规**：
  - 添加 Apple Events 沙盒临时例外授权（`com.apple.finder`），修复 Cmd+; 在沙盒中失效的问题。
  - 移除未使用的 WebKit 私有 SPI（`sel_getUid`/`unsafeBitCast`/`drawsBackground`）。
  - 清理硬编码的开发者 Desktop 路径。
- **Xcode .app 构建**：
  - Run Script 将 SPM 资源从 .bundle 提取到 `Contents/Resources/`，根目录不再有未签名的 .bundle 文件。
  - 构建时自动生成 dSYM 并复制到 archive，解决 App Store 上传缺少符号文件的问题。
- **Bundle.module 安全化**：`Bundle.module` 改用 `Bundle(path:)` 按需加载，避免 .bundle 不存在时 crash。
- **图标加载回退**：`loadTemplateImage` 依次尝试 `Bundle.main`（扁平图标）和 module bundle（分类子目录），修复 Xcode 构建下分类图标不显示的问题。

## 已知坑点

- Info.plist 通过 linker flag `-sectcreate __TEXT __info_plist` 嵌入，路径是绝对路径，目录改名后要更新 Package.swift
- 菜单栏图标优先 PNG（`TmpspaceMenuBar/Sources/icon/tmp.svg`）
- CodeMirror `highlightSpecialChars()` 是静态扩展，用 WKUserScript 注入 CSS 覆盖 `.cm-specialChar`
- App 用 `NSApp.setActivationPolicy(.accessory)` 实现菜单栏模式

## 协作风格

- UI 中文，回复简洁，不加尾注和 emoji
- 快速迭代：改完就构建启动，少解释
