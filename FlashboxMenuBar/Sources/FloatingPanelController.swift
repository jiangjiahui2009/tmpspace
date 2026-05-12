import AppKit
import FlashboxCore

// MARK: - Tag constants

/// Tag applied to the content area view so that Phase 2 can locate and swap it.
enum PanelViewTag {
    /// The NSTextView (placeholder editor) tag.
    static let editorContent = 9001
    /// The custom toolbar container view tag.
    static let toolbarContainer = 9002
}

/// An NSPanel-based window controller that hosts a floating markdown editor panel.
///
/// Behaviour:
/// - Floats above other windows without stealing focus (`.nonactivatingPanelMask`).
/// - User-draggable and resizable, just like macOS Stickies.
/// - Window close hides the panel rather than destroying it.
/// - Keyboard shortcuts cmd+N / cmd+S are handled via a local event monitor.
@MainActor
final class FloatingPanelController: NSWindowController, NSWindowDelegate {

    // MARK: - Properties

    /// The panel model this controller represents.
    /// Declared `var` because `PanelModel` is a value type whose properties
    /// are mutated in-place (position / visibility).
    var panelModel: PanelModel

    /// When `true`, `windowShouldClose` returns `true` so the window can be
    /// fully closed (used during deletion). In normal operation it stays `false`
    /// and the close button merely hides the panel.
    private var shouldAllowClose = false

    /// Callback invoked when the panel requests creation of a new panel (cmd+N).
    var onCreateNewPanel: (() -> Void)?

    /// A weak reference to the PanelManager, used for deletion requests.
    weak var panelManager: PanelManager?

    /// The placeholder editor text view (replaced when editorProvider is set).
    private var textView: NSTextView!

    /// The toolbar container view that sits at the top of the content area.
    private var toolbarView: NSView!

    /// Local event monitor token for keyboard shortcuts.
    private nonisolated(unsafe) var localEventMonitor: Any?

    /// Editor provider — when set, swaps placeholder text view for real editor.
    var editorProvider: EditorProviderProtocol? {
        didSet {
            DebugLog.log("FloatingPanelController.editorProvider didSet — provider=\(editorProvider != nil ? "exists" : "nil")")
            if editorProvider != nil {
                swapPlaceholderForEditor()
            }
        }
    }

    /// Called when the editor content changes (panelId, newContent).
    var onContentChanged: ((UUID, String) -> Void)?

    // MARK: - Init

    init(panelModel: PanelModel) {
        self.panelModel = panelModel
        super.init(window: nil)
        DebugLog.log("FloatingPanelController.init — building window...")
        buildWindow()
        DebugLog.log("FloatingPanelController.init — window built, isVisible=\(window?.isVisible ?? false)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Window construction

    private func buildWindow() {
        let window = NSWindow(
            contentRect: frameForModel(),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        window.level = NSWindow.Level.floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Hide standard title bar buttons (close, minimize, zoom).
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        window.collectionBehavior = NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])

        // Content setup — bottom-up so the toolbar sits above the editor.
        let contentView = window.contentView!
        contentView.wantsLayer = true
        contentView.autoresizesSubviews = true

        // 1. Placeholder editor (NSTextView inside a clip-view inside a scroll view).
        let scrollView = buildEditorScrollView(frame: contentView.bounds)
        scrollView.identifier = NSUserInterfaceItemIdentifier("editorContent")  // PanelViewTag.editorContent
        contentView.addSubview(scrollView)

        // 2. Toolbar (custom 32 pt bar at the top).
        toolbarView = buildToolbarView()
        toolbarView.identifier = NSUserInterfaceItemIdentifier("toolbarContainer")  // PanelViewTag.toolbarContainer
        contentView.addSubview(toolbarView)

        // Layout constraints.
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 32),

            scrollView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Minimum size so the window never collapses to nothing.
        window.minSize = NSSize(width: Constants.minPanelWidth, height: Constants.minPanelHeight + 32)

        // Apply the initial colour theme.
        ColorThemeManager.shared.applyTheme(panelModel.colorTheme, to: self)

        self.window = window

        // Make the placeholder text view the first responder so the cursor
        // appears immediately when the panel is shown.
        window.makeFirstResponder(textView)

        // Start monitoring keyboard shortcuts.
        installLocalEventMonitor()
    }

    // MARK: - Editor view swap (Phase 2 integration)

    /// Replace the placeholder NSTextView with the real CodeMirror 6 editor view.
    private func swapPlaceholderForEditor() {
        DebugLog.log("swapPlaceholderForEditor called")
        guard let provider = editorProvider else { DebugLog.log("swapPlaceholderForEditor — editorProvider is nil, bailing"); return }
        guard let window else { DebugLog.log("swapPlaceholderForEditor — window is nil, bailing"); return }

        let contentView = window.contentView!
        DebugLog.log("swapPlaceholderForEditor — contentView bounds=\(NSStringFromRect(contentView.bounds))")

        // 1. Find and remove the placeholder scroll view (tag 9001)
        if let placeholderScrollView = contentView.subviews.first(where: { $0.identifier == NSUserInterfaceItemIdentifier("editorContent") }) as? NSScrollView {
            DebugLog.log("swapPlaceholderForEditor — placeholderFrame=\(NSStringFromRect(placeholderScrollView.frame))")
            // Capture any text the user may have typed in the placeholder.
            let existingText = textView?.string ?? ""

            placeholderScrollView.removeFromSuperview()

            // 2. Create the real editor view
            let editorView = provider.createEditorView(for: panelModel.id)
            DebugLog.log("swapPlaceholderForEditor — editorView created: type=\(type(of: editorView)), frame=\(NSStringFromRect(editorView.frame))")
            editorView.identifier = NSUserInterfaceItemIdentifier("editorContent")  // PanelViewTag.editorContent
            editorView.translatesAutoresizingMaskIntoConstraints = false
            editorView.frame = placeholderScrollView.frame

            // 3. If there was placeholder content, restore it into the editor
            if !existingText.isEmpty {
                provider.setContent(for: panelModel.id, content: existingText)
            }

            contentView.addSubview(editorView)

            // Make the editor view first responder so it gets the cursor.
            let becameFirst = window.makeFirstResponder(editorView)
            DebugLog.log("swapPlaceholderForEditor — makeFirstResponder returned \(becameFirst), firstResponder=\(String(describing: window.firstResponder)), isKeyWindow=\(window.isKeyWindow)")

            // 4. Re-apply constraints (editorView replaces scrollView in layout)
            if let toolbarView = contentView.subviews.first(where: { $0.identifier == NSUserInterfaceItemIdentifier("toolbarContainer") }) {
                NSLayoutConstraint.activate([
                    editorView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
                    editorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    editorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    editorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                ])
                // Force immediate layout so the editorView gets a valid frame.
                contentView.layoutSubtreeIfNeeded()
                DebugLog.log("swapPlaceholderForEditor — after layout, editorView frame=\(NSStringFromRect(editorView.frame))")
            } else {
                DebugLog.log("swapPlaceholderForEditor — ERROR: toolbarView not found, editorView won't have constraints!")
            }
        }
    }

    // MARK: - Keyboard shortcuts

    private func installLocalEventMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isVisible == true else { return event }

            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()

            if modifierFlags == .command, key == "n" {
                self.onCreateNewPanel?()
                return nil
            }

            if modifierFlags == .command, key == "s" {
                self.saveAsDocumentTapped()
                return nil
            }

            return event
        }
    }

    // MARK: - Toolbar construction

    private func buildToolbarView() -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        bar.wantsLayer = true
        bar.autoresizesSubviews = true

        // --- Miniaturize (hide) button ---
        let miniaturizeBtn = makeToolbarButton(
            symbolName: "minus",
            tooltip: "隐藏面板",
            action: #selector(miniaturizePanel)
        )
        bar.addSubview(miniaturizeBtn)

        // --- Format button (right side, next to more) ---
        let formatBtn = makeToolbarButton(
            symbolName: "checklist",
            tooltip: "格式化",
            action: #selector(formatTapped)
        )
        bar.addSubview(formatBtn)

        // --- Clear button (right side, next to more) ---
        let clearBtn = makeToolbarButton(
            symbolName: "eraser",
            tooltip: "清空内容",
            action: #selector(clearTapped)
        )
        bar.addSubview(clearBtn)

        // --- More button (right-aligned, shows popup menu on click) ---
        let moreBtn = makeToolbarButton(
            symbolName: "ellipsis.circle",
            tooltip: "更多操作",
            action: #selector(moreButtonClicked(_:))
        )
        bar.addSubview(moreBtn)

        // Layout
        miniaturizeBtn.translatesAutoresizingMaskIntoConstraints = false
        formatBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        moreBtn.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Left: miniaturize button
            miniaturizeBtn.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            miniaturizeBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            miniaturizeBtn.widthAnchor.constraint(equalToConstant: 28),
            miniaturizeBtn.heightAnchor.constraint(equalToConstant: 24),

            // Right: more button
            moreBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            moreBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            moreBtn.widthAnchor.constraint(equalToConstant: 28),
            moreBtn.heightAnchor.constraint(equalToConstant: 24),

            // Clear button (to the left of more)
            clearBtn.trailingAnchor.constraint(equalTo: moreBtn.leadingAnchor, constant: -6),
            clearBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            clearBtn.widthAnchor.constraint(equalToConstant: 28),
            clearBtn.heightAnchor.constraint(equalToConstant: 24),

            // Format button (to the left of clear)
            formatBtn.trailingAnchor.constraint(equalTo: clearBtn.leadingAnchor, constant: -6),
            formatBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            formatBtn.widthAnchor.constraint(equalToConstant: 28),
            formatBtn.heightAnchor.constraint(equalToConstant: 24),
        ])

        return bar
    }

    private func makeToolbarButton(
        symbolName: String,
        tooltip: String,
        action: Selector?
    ) -> NSButton {
        let btn = NSButton(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)!,
                           target: self,
                           action: action)
        btn.bezelStyle = .smallSquare
        btn.isBordered = false
        btn.toolTip = tooltip
        btn.imagePosition = .imageOnly
        return btn
    }

    private func buildEditorScrollView(frame: NSRect) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let clipView = NSClipView(frame: scrollView.bounds)
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        textView = NSTextView(frame: clipView.bounds)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: clipView.bounds.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.identifier = NSUserInterfaceItemIdentifier("editorContent")  // PanelViewTag.editorContent

        scrollView.documentView = textView

        return scrollView
    }

    // MARK: - More menu

    private func buildMoreMenu() -> NSMenu {
        let menu = NSMenu(title: "更多操作")

        let saveItem = NSMenuItem(
            title: "保存为文档",
            action: #selector(saveAsDocumentTapped),
            keyEquivalent: ""
        )
        saveItem.target = self
        menu.addItem(saveItem)

        let deleteItem = NSMenuItem(
            title: "删除",
            action: #selector(deletePanelTapped),
            keyEquivalent: ""
        )
        deleteItem.target = self
        menu.addItem(deleteItem)

        return menu
    }

    // MARK: - Public helpers

    /// Called by ColorThemeManager to set the toolbar area background.
    func applyToolbarBackground(_ color: NSColor) {
        toolbarView?.layer?.backgroundColor = color.cgColor
    }

    /// Computes the initial frame from the model (with a sensible fallback).
    private func frameForModel() -> NSRect {
        let size = panelModel.size
        if let pos = panelModel.position {
            return NSRect(origin: pos, size: size)
        }
        // Default: centre the panel on the main screen.
        guard let screen = NSScreen.main else {
            return NSRect(x: 200, y: 200, width: size.width, height: size.height)
        }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.midY - size.height / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Actions

    @objc private func miniaturizePanel() {
        window?.orderOut(nil)
        panelModel.isVisible = false
        persistFrameIfNeeded()
    }

    @objc private func formatTapped(_ sender: NSButton) {
        let menu = NSMenu(title: "格式化")
        let unorderedItem = NSMenuItem(title: "无序列表", action: #selector(applyUnorderedList), keyEquivalent: "")
        unorderedItem.target = self
        let orderedItem = NSMenuItem(title: "有序列表", action: #selector(applyOrderedList), keyEquivalent: "")
        orderedItem.target = self
        let taskItem = NSMenuItem(title: "待办事项", action: #selector(applyTaskList), keyEquivalent: "")
        taskItem.target = self
        menu.addItem(unorderedItem)
        menu.addItem(orderedItem)
        menu.addItem(taskItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height),
            in: sender
        )
    }

    @objc private func applyUnorderedList() {
        editorProvider?.executeCommand(for: panelModel.id, command: .unorderedList)
    }
    @objc private func applyOrderedList() {
        editorProvider?.executeCommand(for: panelModel.id, command: .orderedList)
    }
    @objc private func applyTaskList() {
        editorProvider?.executeCommand(for: panelModel.id, command: .taskList)
    }

    @objc private func clearTapped() {
        if let provider = editorProvider {
            provider.executeCommand(for: panelModel.id, command: .clearAll)
        } else {
            textView?.string = ""
        }
    }

    @objc private func saveAsDocumentTapped() {
        let content: String
        if let provider = editorProvider {
            content = provider.getContent(for: panelModel.id)
        } else {
            content = textView?.string ?? ""
        }
        saveContentAsFile(content)
    }

    private func saveContentAsFile(_ content: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "未命名.md"
        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
            // After saving, clear current panel content.
            if let provider = self.editorProvider {
                provider.setContent(for: self.panelModel.id, content: "")
            } else {
                self.textView?.string = ""
            }
        }
    }

    @objc private func moreButtonClicked(_ sender: NSButton) {
        let menu = buildMoreMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height),
            in: sender
        )
    }

    @objc private func deletePanelTapped() {
        panelManager?.deletePanel(id: panelModel.id)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if shouldAllowClose {
            return true
        }
        // Hide instead of destroy.
        sender.orderOut(nil)
        panelModel.isVisible = false
        persistFrameIfNeeded()
        return false
    }

    func windowDidResize(_ notification: Notification) {
        persistFrameIfNeeded()
    }

    func windowDidMove(_ notification: Notification) {
        persistFrameIfNeeded()
    }

    /// Tear down the window fully so it can be released from memory.
    /// Called by `PanelManager.deletePanel(id:)`.
    func closePanelCompletely() {
        // Break the delegate link so `windowShouldClose` is not consulted again.
        window?.delegate = nil

        // Tear down the keyboard-event monitor.
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }

        shouldAllowClose = true
        window?.close()
    }

    // MARK: - Persistence

    private func persistFrameIfNeeded() {
        guard let window else { return }
        let frame = window.frame
        panelModel.positionX = frame.origin.x
        panelModel.positionY = frame.origin.y
        panelModel.width = frame.size.width
        panelModel.height = frame.size.height
    }

    // MARK: - Deinit

    deinit {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
