import AppKit
import UniformTypeIdentifiers
import TmpspaceCore

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

    /// Title label in the toolbar center (used by obsidian panel to show .md file name).
    private var toolbarTitleLabel: NSTextField!

    /// Manages temporary file storage for this panel.
    let fileBoxManager = FileBoxManager()

    /// The file box view displayed below the editor.
    private var fileBoxView: FileBoxView!

    /// Whether the file box is currently visible.
    private var isFileBoxVisible = false

    /// Height constraint for the file box (0 = hidden, FileBoxView.preferredHeight = visible).
    private var fileBoxHeightConstraint: NSLayoutConstraint!

    /// Bottom constraint for the editor scroll view (changes when file box toggles).
    private var editorBottomConstraint: NSLayoutConstraint!

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

        // Wire up file box callbacks.
        fileBoxView.onDeleteFile = { [weak self] fileURL in
            guard let self else { return }
            self.fileBoxManager.deleteFile(fileURL)
            let files = self.fileBoxManager.files()
            self.fileBoxView.reload(with: files)
        }

        NotificationCenter.default.addObserver(
            forName: .fileBoxDidReceiveFiles,
            object: fileBoxView!,
            queue: .main
        ) { [weak self] notification in
            guard let self, let url = notification.userInfo?["url"] as? URL else { return }
            Task { @MainActor in
                self.handleFileDropped(url)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .tmpspaceEditorDragEntered,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let panelId = notification.userInfo?["panelId"] as? UUID,
                  panelId == self.panelModel.id else { return }
            Task { @MainActor [weak self] in
                self?.expandFileBox()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .tmpspaceEditorDidReceiveFiles,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let panelId = notification.userInfo?["panelId"] as? UUID,
                  panelId == self.panelModel.id,
                  let urls = notification.userInfo?["urls"] as? [URL] else { return }
            Task { @MainActor [weak self] in
                for url in urls {
                    self?.handleFileDropped(url)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .tmpspaceDropZoneDidReceiveFiles,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isFileBoxVisible else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let files = self.fileBoxManager.files()
                self.fileBoxView.reload(with: files)
            }
        }

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

        window.level = panelModel.alwaysOnTop ? NSWindow.Level.floating : NSWindow.Level.normal
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
        let dragView = EditorDragView(frame: window.contentRect(forFrameRect: window.frame))
        dragView.wantsLayer = true
        dragView.autoresizesSubviews = true
        dragView.onFileDragEntered = { [weak self] in self?.expandFileBox() }
        dragView.onFileDrop = { [weak self] urls in
            guard let self else { return }
            for url in urls { self.handleFileDropped(url) }
        }
        window.contentView = dragView
        let contentView = dragView

        // 1. Placeholder editor (NSTextView inside a clip-view inside a scroll view).
        let scrollView = buildEditorScrollView(frame: contentView.bounds)
        scrollView.identifier = NSUserInterfaceItemIdentifier("editorContent")  // PanelViewTag.editorContent
        contentView.addSubview(scrollView)

        // 2. Toolbar (custom 32 pt bar at the top).
        toolbarView = buildToolbarView()
        toolbarView.identifier = NSUserInterfaceItemIdentifier("toolbarContainer")  // PanelViewTag.toolbarContainer
        contentView.addSubview(toolbarView)

        // 3. File box (initially hidden, displayed below the editor).
        fileBoxView = FileBoxView(frame: .zero)
        fileBoxView.translatesAutoresizingMaskIntoConstraints = false
        fileBoxView.isHidden = true
        contentView.addSubview(fileBoxView)

        // Layout constraints.
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // The editor's bottom is anchored to the file box top, so the file box
        // can slide up from the bottom without affecting the editor constraints.
        editorBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: fileBoxView.topAnchor)
        fileBoxHeightConstraint = fileBoxView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 32),

            scrollView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            editorBottomConstraint,

            fileBoxView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            fileBoxView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            fileBoxView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            fileBoxHeightConstraint,
        ])

        // Minimum size so the window never collapses to nothing.
        window.minSize = NSSize(width: Constants.minPanelWidth, height: Constants.minPanelHeight + 32)

        // Apply the initial chrome colour from the current syntax theme.
        let settings = EditorDisplaySettings.load()
        applyChromeFromSettings(settings)

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
                // Deactivate the old scrollView bottom constraint and create a new
                // one for the editorView that still respects the file box.
                editorBottomConstraint.isActive = false
                let newBottomConstraint = editorView.bottomAnchor.constraint(equalTo: fileBoxView.topAnchor)
                newBottomConstraint.isActive = true
                editorBottomConstraint = newBottomConstraint

                NSLayoutConstraint.activate([
                    editorView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
                    editorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    editorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    newBottomConstraint,
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

            if modifierFlags == .command, key == "w" {
                self.miniaturizePanel()
                return nil
            }

            if modifierFlags == .command, key == "l" {
                self.editorProvider?.executeCommand(for: self.panelModel.id, command: .taskList)
                return nil
            }

            return event
        }
    }

    // MARK: - Toolbar construction

    private func buildToolbarView() -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.clear.cgColor
        bar.autoresizesSubviews = true

        // Visual effect view — frosted glass behind toolbar buttons.
        let effectView = NSVisualEffectView(frame: bar.bounds)
        effectView.material = .titlebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.alphaValue = 0.7
        effectView.autoresizingMask = [.width, .height]
        effectView.identifier = NSUserInterfaceItemIdentifier("toolbarEffect")
        bar.addSubview(effectView)

        // --- Miniaturize (hide) button ---
        let miniaturizeBtn = makeToolbarButton(
            symbolName: "minus",
            tooltip: "隐藏面板",
            action: #selector(miniaturizePanel)
        )
        bar.addSubview(miniaturizeBtn)

        // --- File Box toggle button ---
        let fileBoxBtn = makeToolbarButton(
            symbolName: "cube",
            tooltip: "文件暂存",
            action: #selector(toggleFileBox)
        )
        bar.addSubview(fileBoxBtn)

        // --- Format button (right side, next to more) ---
        let formatBtn = makeToolbarButton(
            symbolName: "checklist",
            tooltip: "格式化",
            action: #selector(formatTapped)
        )
        bar.addSubview(formatBtn)

        // --- Title label (centered, hidden by default) ---
        toolbarTitleLabel = NSTextField(labelWithString: "")
        toolbarTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        toolbarTitleLabel.textColor = .secondaryLabelColor
        toolbarTitleLabel.alignment = .left
        toolbarTitleLabel.lineBreakMode = .byTruncatingMiddle
        toolbarTitleLabel.isHidden = true
        bar.addSubview(toolbarTitleLabel)

        // --- More button (right-aligned, shows popup menu on click) ---
        let moreBtn = makeToolbarButton(
            symbolName: "ellipsis.circle",
            tooltip: "更多操作",
            action: #selector(moreButtonClicked(_:))
        )
        bar.addSubview(moreBtn)

        // Layout
        toolbarTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        miniaturizeBtn.translatesAutoresizingMaskIntoConstraints = false
        fileBoxBtn.translatesAutoresizingMaskIntoConstraints = false
        formatBtn.translatesAutoresizingMaskIntoConstraints = false
        moreBtn.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Left: miniaturize button
            miniaturizeBtn.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            miniaturizeBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            miniaturizeBtn.widthAnchor.constraint(equalToConstant: 28),
            miniaturizeBtn.heightAnchor.constraint(equalToConstant: 24),

            // Title label (right of miniaturize button)
            toolbarTitleLabel.leadingAnchor.constraint(equalTo: miniaturizeBtn.trailingAnchor, constant: 6),
            toolbarTitleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            toolbarTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: formatBtn.leadingAnchor, constant: -8),

            // File Box button (to the left of more button)
            fileBoxBtn.trailingAnchor.constraint(equalTo: moreBtn.leadingAnchor, constant: -6),
            fileBoxBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            fileBoxBtn.widthAnchor.constraint(equalToConstant: 28),
            fileBoxBtn.heightAnchor.constraint(equalToConstant: 24),

            // Right: more button
            moreBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            moreBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            moreBtn.widthAnchor.constraint(equalToConstant: 28),
            moreBtn.heightAnchor.constraint(equalToConstant: 24),

            // Format button (to the left of file box)
            formatBtn.trailingAnchor.constraint(equalTo: fileBoxBtn.leadingAnchor, constant: -6),
            formatBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            formatBtn.widthAnchor.constraint(equalToConstant: 28),
            formatBtn.heightAnchor.constraint(equalToConstant: 24),
        ])

        return bar
    }

    /// Set the toolbar center title (used by obsidian panel to show .md file name).
    func setToolbarTitle(_ title: String) {
        toolbarTitleLabel.stringValue = title
        toolbarTitleLabel.isHidden = title.isEmpty
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

        // Prevent NSTextView from consuming file drags so they bubble to contentView.
        textView.unregisterDraggedTypes()

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

        let openTempSpaceItem = NSMenuItem(
            title: "打开临时空间",
            action: #selector(openTempSpaceTapped),
            keyEquivalent: ""
        )
        openTempSpaceItem.target = self
        menu.addItem(openTempSpaceItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "偏好设置",
            action: #selector(openPreferencesTapped),
            keyEquivalent: ""
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(
            title: "清空内容",
            action: #selector(clearTapped),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)

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

    /// Update chrome (toolbar background + window appearance) from syntax theme.
    func applyChromeFromSettings(_ settings: EditorDisplaySettings) {
        guard let window else { return }
        window.appearance = settings.effectiveAppearance

        if settings.reduceToolbarTransparency {
            window.isOpaque = true
            window.backgroundColor = settings.chromeColor
        } else {
            window.isOpaque = false
            window.backgroundColor = settings.chromeColor.withAlphaComponent(0.85)
        }

        // Keep editor content area opaque so text stays sharp.
        if let editorView = window.contentView?.subviews.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("editorContent")
        }) {
            if let scrollView = editorView as? NSScrollView {
                scrollView.contentView.drawsBackground = true
                scrollView.contentView.backgroundColor = settings.chromeColor
            }
            editorView.layer?.backgroundColor = settings.chromeColor.cgColor
        }

        // Toggle between frosted-glass blur and solid opaque background.
        if let effectView = toolbarView?.subviews.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("toolbarEffect")
        }) as? NSVisualEffectView {
            effectView.isHidden = settings.reduceToolbarTransparency
        }
        toolbarView?.layer?.backgroundColor = settings.reduceToolbarTransparency
            ? settings.chromeColor.cgColor
            : NSColor.clear.cgColor
    }

    /// Called by ColorThemeManager to set the toolbar area background.
    func applyToolbarBackground(_ color: NSColor) {
        toolbarView?.layer?.backgroundColor = color.cgColor
    }

    /// Update the window level dynamically when the "always on top" preference changes.
    func updateAlwaysOnTop(_ alwaysOnTop: Bool) {
        panelModel.alwaysOnTop = alwaysOnTop
        window?.level = alwaysOnTop ? NSWindow.Level.floating : NSWindow.Level.normal
    }

    // MARK: - Frame positioning

    /// Computes the initial frame: respects a saved position, otherwise
    /// falls back to centering on the main screen (should rarely happen —
    /// `PanelManager` pre-sets a valid position for every new panel).
    private func frameForModel() -> NSRect {
        let size = panelModel.size
        if let pos = panelModel.position {
            return NSRect(origin: pos, size: size)
        }
        guard let screen = NSScreen.main else {
            return NSRect(x: 200, y: 200, width: size.width, height: size.height)
        }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Actions

    @objc private func miniaturizePanel() {
        window?.orderOut(nil)
        panelModel.isVisible = false
        persistFrameIfNeeded()
        NotificationCenter.default.post(
            name: .tmpspacePanelsVisibilityDidChange,
            object: self
        )
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

    // MARK: - Save panel

    /// File format options for the save panel accessory view.
    private static let saveFormats: [(title: String, ext: String, utType: UTType)] = [
        ("Markdown",     "md",       .plainText),
        ("纯文本",       "txt",      .plainText),
    ]

    private func saveContentAsFile(_ content: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "未命名.md"
        savePanel.accessoryView = makeSaveAccessoryView(for: savePanel)
        guard let window else { return }
        savePanel.beginSheetModal(for: window) { [weak self] response in
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

    /// Build an accessory view for the save panel with a file format picker,
    /// laid out as a horizontal form row matching the system save panel fields
    /// (保存为： / 标签： / 位置：) so the controls align vertically.
    private func makeSaveAccessoryView(for savePanel: NSSavePanel) -> NSView {
        // Add generous top padding so the separator line doesn't crowd the content.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        container.translatesAutoresizingMaskIntoConstraints = false

        // Narrower label column so the popup leading edge aligns with the
        // system fields above (Save As text field / Where popup).
        let labelWidth: CGFloat = 72

        let formatLabel = NSTextField(labelWithString: "文件格式：")
        formatLabel.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        formatLabel.alignment = .right
        formatLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(formatLabel)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        popup.controlSize = .regular
        for fmt in Self.saveFormats {
            popup.addItem(withTitle: "\(fmt.title) (.\(fmt.ext))")
            popup.lastItem?.representedObject = fmt
        }
        popup.target = self
        popup.action = #selector(saveFormatDidChange(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(popup)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 320),

            formatLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            formatLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            formatLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),

            popup.leadingAnchor.constraint(equalTo: formatLabel.trailingAnchor, constant: 6),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: formatLabel.centerYAnchor),
        ])

        // Store the save panel reference on the popup for the action callback.
        objc_setAssociatedObject(popup, "savePanel", savePanel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        return container
    }

    @objc private func saveFormatDidChange(_ sender: NSPopUpButton) {
        guard let savePanel = objc_getAssociatedObject(sender, "savePanel") as? NSSavePanel,
              let fmt = sender.selectedItem?.representedObject as? (title: String, ext: String, utType: UTType) else { return }

        let name = savePanel.nameFieldStringValue
        let baseName = (name as NSString).deletingPathExtension
        savePanel.nameFieldStringValue = "\(baseName).\(fmt.ext)"
        savePanel.allowedContentTypes = [fmt.utType]
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

    @objc private func openTempSpaceTapped() {
        let raw = UserDefaults.standard.string(forKey: "fileBoxFolderPath") ?? ""
        let folderURL: URL
        if raw.isEmpty {
            folderURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents")
                .appendingPathComponent("Tmpspace")
        } else {
            folderURL = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }

    @objc private func openPreferencesTapped() {
        NotificationCenter.default.post(name: .tmpspaceOpenPreferences, object: nil)
    }

    // MARK: - File box

    @objc private func toggleFileBox() {
        isFileBoxVisible.toggle()
        fileBoxView.isHidden = !isFileBoxVisible
        fileBoxHeightConstraint.constant = isFileBoxVisible ? FileBoxView.preferredHeight : 0

        // Apply layout first so the collection view has a non-zero frame,
        // then reload data so cells are rendered properly.
        fileBoxView.layoutSubtreeIfNeeded()

        if isFileBoxVisible {
            let files = fileBoxManager.files()
            fileBoxView.reload(with: files)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Expand the file box (no-op if already visible).
    private func expandFileBox() {
        guard !isFileBoxVisible else { return }
        isFileBoxVisible = true
        fileBoxView.isHidden = false
        fileBoxHeightConstraint.constant = FileBoxView.preferredHeight
        // Apply layout first so the collection view has a non-zero frame before reload.
        fileBoxView.layoutSubtreeIfNeeded()
        fileBoxView.reload(with: fileBoxManager.files())
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Handle files dropped into the file box.
    private func handleFileDropped(_ url: URL) {
        guard fileBoxManager.addFile(url) != nil else { return }
        if isFileBoxVisible {
            let files = fileBoxManager.files()
            fileBoxView.reload(with: files)
        }
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
        NotificationCenter.default.post(
            name: .tmpspacePanelsVisibilityDidChange,
            object: self
        )
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

// MARK: - Drag-aware content view

/// A content view that detects file drags over the editor area and forwards
/// them as callbacks so the file box can auto-expand and accept drops.
private final class EditorDragView: NSView {

    var onFileDragEntered: (() -> Void)?
    var onFileDragExited: (() -> Void)?
    var onFileDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DebugLog.log("EditorDragView.draggingEntered — hasFileURLs=\(hasFileURLs(sender))")
        guard hasFileURLs(sender) else { return [] }
        DebugLog.log("EditorDragView.draggingEntered — calling onFileDragEntered")
        onFileDragEntered?()
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        DebugLog.log("EditorDragView.performDragOperation")
        guard let urls = readFileURLs(sender), !urls.isEmpty else { return false }
        DebugLog.log("EditorDragView.performDragOperation — urls=\(urls.map(\.lastPathComponent))")
        onFileDrop?(urls)
        return true
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        DebugLog.log("EditorDragView.draggingExited")
        onFileDragExited?()
    }

    private func hasFileURLs(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    private func readFileURLs(_ sender: any NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    }
}
