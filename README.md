# Flashbox (轻闪框) - Module Development Guide

> Flashbox is a super-lightweight macOS menu bar Markdown editor, forked from MarkEdit.
> This document is for developers working on parallel module development.

## Project Structure

```
Flashbox/
├── MarkEdit-main/           # Forked MarkEdit base (MIT License)
│   ├── CoreEditor/          # TypeScript/CodeMirror 6 editor core
│   ├── MarkEditKit/         # Swift↔JS bridge framework
│   ├── MarkEditCore/        # Swift shared editor logic
│   ├── MarkEditMac/         # Original macOS document editor
│   └── MarkEdit.xcodeproj   # Original Xcode project
│
├── FlashboxCore/            # Shared interfaces & data models (Phase 0)
│   └── Sources/
│       ├── PanelModel.swift
│       ├── PanelColorTheme.swift
│       ├── Constants.swift
│       └── Protocols/
│           ├── PanelStorageProtocol.swift
│           ├── EditorProviderProtocol.swift
│           └── MenuBarManagerProtocol.swift
│
├── FlashboxMenuBar/         # Menu bar + panel shell (Phase 1 - Conversation A)
│   └── Sources/
│       ← Develop: MenuBarController, PanelManager, FloatingPanelController
│
├── FlashboxEditor/          # Editor integration (Phase 1 - Conversation B)
│   └── Sources/
│       ← Develop: EditorViewController, EditorBridge, FormatToolbar
│
├── FlashboxStorage/         # Persistence & encryption (Phase 1 - Conversation C)
│   └── Sources/
│       ← Develop: PanelStorage, EncryptionService, AutoSaveManager
│
├── FlashboxSettings/        # Settings & system integration (Phase 1 - Conversation D)
│   └── Sources/
│       ← Develop: SettingsView, GlobalShortcutManager, AppDelegate
│
└── FlashboxApp/             # Final app target (Phase 2 integration)
    └── Info.plist
```

## Module Dependencies

```
                    ┌─────────────┐
                    │ FlashboxCore│  (No dependencies)
                    └──────┬──────┘
           ┌───────────────┼───────────────┐
           │               │               │
    ┌──────┴──────┐ ┌──────┴──────┐ ┌──────┴──────┐
    │FlashboxMenu │ │FlashboxEdit │ │FlashboxStor │
    │    Bar      │ │    or       │ │    age      │
    └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │               │               │
           └───────────────┼───────────────┘
                           │
                    ┌──────┴──────┐
                    │FlashboxSett │
                    │    ings     │
                    └─────────────┘
```

## Swift Package Manager Setup

Each module is a Swift Package (swift-tools-version 6.0, macOS 15+).
To add to Xcode: File → Add Package Dependencies → Add Local → select module folder.

## Shared Interface Contracts

### PanelModel (FlashboxCore)
```swift
struct PanelModel: Identifiable, Codable {
    let id: UUID
    var content: String       // Markdown content
    var title: String
    var positionX: CGFloat, positionY: CGFloat
    var width: CGFloat, height: CGFloat
    var colorTheme: PanelColorTheme
    var isVisible: Bool
    var createdAt: Date, lastModifiedAt: Date
}
```

### Protocols to implement:

| Protocol | Implemented by | Description |
|----------|---------------|-------------|
| `MenuBarManagerProtocol` | FlashboxMenuBar | Panel lifecycle, show/hide, menu bar |
| `EditorProviderProtocol` | FlashboxEditor | Create editor views, get/set content, commands |
| `PanelStorageProtocol` | FlashboxStorage | Save/Load/Delete panels, auto-save |

## Development Notes

### For Conversation A (MenuBar):
- Build against FlashboxCore only
- Use `NSTextView` as editor placeholder (swap real editor in Phase 2)
- Test: create/destroy panels, check lifecycle, drag/resize

### For Conversation B (Editor):
- Build against FlashboxCore only
- Test editor in standalone `NSWindow` (no menu bar dependency)
- Reuse CoreEditor JS bundle from MarkEdit-main/CoreEditor/dist/

### For Conversation C (Storage):
- Build against FlashboxCore only
- Pure logic module, testable with unit tests
- Implement `PanelStorageProtocol`, use CryptoKit

### For Conversation D (Settings):
- Build against FlashboxCore only
- No dependency on other Flashbox modules
- Handle system-level concerns (shortcuts, appearance, lifecycle)

## Integration Points (Phase 2)

1. **Editor into Panel**: `panel.setContentView(editorProvider.createEditorView(for: panelId))`
2. **Storage into Editor**: Editor content changes → `storage.panelContentDidChange(id, content)`
3. **Storage into MenuBar**: Panel create/delete → `storage.savePanel/deletePanel`
4. **Shortcuts into MenuBar**: `GlobalShortcutManager.toggle` → `menuBarManager.togglePanels()`

## Original MarkEdit Architecture (for reference)

```
CoreEditor (JS/CodeMirror 6) ←→ MarkEditKit (Bridge) ←→ MarkEditMac (AppKit UI)
```

- Editor is WKWebView running CodeMirror 6
- ts-gyb generates Swift bridge code from TypeScript interfaces
- Swift-to-JS: `webView.invoke(path:message:)`
- JS-to-Swift: `WKScriptMessageHandler` with `name == "bridge"`
