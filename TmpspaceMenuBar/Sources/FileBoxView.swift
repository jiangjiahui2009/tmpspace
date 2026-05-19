//
//  FileBoxView.swift
//  TmpspaceMenuBar
//
//  A collapsible view displaying dropped files as clickable icons.
//  Supports drag-in from Finder, drag-out to other apps, and right-click deletion.
//

import AppKit
import TmpspaceCore

/// A collapsible horizontal file strip that accepts drag-and-drop
/// and displays file icons.
final class FileBoxView: NSView {

    // MARK: - Properties

    private var storedFiles: [URL] = []

    /// Called when the user right-clicks and selects "删除".
    var onDeleteFile: ((URL) -> Void)?

    /// Observer for external file box folder changes.
    private var fileBoxChangeObserver: NSObjectProtocol?

    /// The collection view displaying file items.
    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!

    /// Preferred height when visible.
    static let preferredHeight: CGFloat = 120

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUp()
        registerForDraggedTypes([.fileURL])

        fileBoxChangeObserver = NotificationCenter.default.addObserver(
            forName: FileBoxManager.fileBoxDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadFilesFromDisk()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setUp() {
        // Scroll view wrapping the collection view
        scrollView = NSScrollView(frame: bounds)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let flowLayout = NSCollectionViewFlowLayout()
        flowLayout.scrollDirection = .horizontal
        flowLayout.itemSize = NSSize(width: 72, height: 80)
        flowLayout.minimumInteritemSpacing = 8
        flowLayout.minimumLineSpacing = 8
        flowLayout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        collectionView = NSCollectionView(frame: .zero)
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        // Drag mask is updated in reload() to reflect the current mode.
        collectionView.backgroundColors = [.clear]
        collectionView.register(FileItem.self, forItemWithIdentifier: FileItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self

        scrollView.documentView = collectionView
        addSubview(scrollView)

        // Folder button — top-right corner, opens the file box folder in Finder.
        let folderBtn = NSButton(
            image: NSImage(systemSymbolName: "folder", accessibilityDescription: Txt.str("打开临时空间文件夹"))!,
            target: self,
            action: #selector(openFolderTapped)
        )
        folderBtn.bezelStyle = .smallSquare
        folderBtn.isBordered = false
        folderBtn.toolTip = Txt.str("打开临时空间文件夹")
        folderBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(folderBtn)

        NSLayoutConstraint.activate([
            folderBtn.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            folderBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            folderBtn.widthAnchor.constraint(equalToConstant: 18),
            folderBtn.heightAnchor.constraint(equalToConstant: 18),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public

    /// Reload the file list from a new set of URLs.
    func reload(with files: [URL]) {
        storedFiles = files
        let mode = UserDefaults.standard.string(forKey: "fileBoxMode") ?? "copy"
        collectionView.setDraggingSourceOperationMask(
            mode == "move" ? .move : .copy,
            forLocal: false
        )
        collectionView.reloadData()
    }

    /// Reload files from the shared folder (triggered by external directory changes).
    func reloadFilesFromDisk() {
        let files = FileBoxManager().files()
        reload(with: files)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Subtle top separator line
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        path.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - Folder button

    @objc private func openFolderTapped() {
        let url = FileBoxManager.folderURL
        // Ensure the directory exists before opening.
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Keyboard shortcut (Cmd+Delete → delete selected file)

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers

        if modifierFlags == .command,
           key == String(Character(UnicodeScalar(NSDeleteCharacter)!)) {
            deleteSelectedFiles()
            return
        }

        if modifierFlags == .command, key == "c" {
            copySelectedFiles()
            return
        }

        super.keyDown(with: event)
    }

    /// Copies the selected file URLs to the general pasteboard so they can
    /// be pasted in Finder or other apps.
    private func copySelectedFiles() {
        let urls: [URL] = collectionView.selectionIndexPaths.compactMap {
            guard $0.item < storedFiles.count else { return nil }
            return storedFiles[$0.item]
        }
        guard !urls.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// Deletes the currently selected file(s) from the file box.
    private func deleteSelectedFiles() {
        for indexPath in collectionView.selectionIndexPaths {
            guard indexPath.item < storedFiles.count else { continue }
            let url = storedFiles[indexPath.item]
            onDeleteFile?(url)
        }
    }

    // MARK: - Right-click context menu

    private func showContextMenu(for fileURL: URL, at point: NSPoint) {
        let menu = NSMenu(title: "")
        let deleteItem = NSMenuItem(
            title: Txt.str("删除"),
            action: #selector(deleteFileFromMenu(_:)),
            keyEquivalent: ""
        )
        deleteItem.target = self
        deleteItem.representedObject = fileURL
        menu.addItem(deleteItem)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func deleteFileFromMenu(_ sender: NSMenuItem) {
        guard let fileURL = sender.representedObject as? URL else { return }
        onDeleteFile?(fileURL)
    }
}

// MARK: - NSDraggingDestination

extension FileBoxView {

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: nil
        ) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL], !items.isEmpty else {
            return false
        }

        // Skip files already in the box (drag-out-and-back, or re-drop from Finder).
        let existingPaths = Set(storedFiles.map {
            $0.resolvingSymlinksInPath().path
        })

        var handled = false
        for url in items {
            if existingPaths.contains(url.resolvingSymlinksInPath().path) {
                continue  // already here — no-op
            }
            NotificationCenter.default.post(
                name: .fileBoxDidReceiveFiles,
                object: self,
                userInfo: ["url": url]
            )
            handled = true
        }
        return handled
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {}
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {}
}

// MARK: - NSCollectionViewDataSource

extension FileBoxView: NSCollectionViewDataSource {
    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        storedFiles.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: FileItem.identifier,
            for: indexPath
        )
        if let fileItem = item as? FileItem {
            let url = storedFiles[indexPath.item]
            fileItem.configure(with: url)
            fileItem.onDoubleClick = { [weak self] fileURL in
                NSWorkspace.shared.open(fileURL)
                self?.collectionView.deselectItems(at: [indexPath])
            }
            fileItem.onRightClick = { [weak self] fileURL in
                guard let self, let window = self.window else { return }
                // Convert to window-relative coordinates for the pop-up menu.
                let itemOrigin = collectionView.convert(
                    collectionView.frameForItem(at: indexPath.item).origin,
                    to: nil
                )
                let point = NSPoint(x: itemOrigin.x + 36, y: itemOrigin.y + 40)
                self.showContextMenu(for: fileURL, at: window.convertPoint(toScreen: point))
            }
        }
        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension FileBoxView: NSCollectionViewDelegate {
    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        // Single-click = visual selection only. The FileItem handles the highlight.
        // Double-click = open file, handled via FileItemView.onDoubleClick.
        // Become first responder so keyboard shortcuts (Cmd+Delete) work.
        if !indexPaths.isEmpty {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: Drag source (drag file out of the box)

    func collectionView(
        _ collectionView: NSCollectionView,
        canDragItemsAt indexPaths: Set<IndexPath>,
        with event: NSEvent
    ) -> Bool {
        true
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        storedFiles[indexPath.item] as NSURL
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItemsAt indexPaths: Set<IndexPath>
    ) {
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        dragOperation operation: NSDragOperation
    ) {
        // In move mode, reload after drag-out — the file may have been moved.
        let mode = UserDefaults.standard.string(forKey: "fileBoxMode") ?? "copy"
        if mode == "move" {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Re-read from disk to reflect any moved files.
                self.storedFiles = FileBoxManager().files()
                collectionView.reloadData()
            }
        }
    }
}

// MARK: - File Item View (custom view with selection highlight and double-click)

/// Custom `NSView` for `FileItem` that draws a selection background and
/// handles double-click to open the file.
private final class FileItemView: NSView {
    var isItemSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var onDoubleClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isItemSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSColor.controlAccentColor.withAlphaComponent(0.4).setStroke()
            let rc = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                  xRadius: 6, yRadius: 6)
            rc.lineWidth = 2
            rc.fill()
            rc.stroke()
        }
    }
}

// MARK: - Collection View Item

private final class FileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileItem")

    private var iconView: NSImageView!
    private var nameLabel: NSTextField!
    private var fileURL: URL?
    var onDoubleClick: ((URL) -> Void)?
    var onRightClick: ((URL) -> Void)?

    override func loadView() {
        view = FileItemView(frame: NSRect(x: 0, y: 0, width: 72, height: 80))
    }

    override var isSelected: Bool {
        didSet {
            (view as? FileItemView)?.isItemSelected = isSelected
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let itemView = view as? FileItemView else { return }
        itemView.onDoubleClick = { [weak self] in
            guard let self, let url = self.fileURL else { return }
            self.onDoubleClick?(url)
        }
        itemView.onRightClick = { [weak self] in
            guard let self, let url = self.fileURL else { return }
            self.onRightClick?(url)
        }

        iconView = NSImageView(frame: NSRect(x: 8, y: 20, width: 56, height: 44))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        view.addSubview(iconView)

        nameLabel = NSTextField(labelWithString: "")
        nameLabel.frame = NSRect(x: 0, y: 0, width: 72, height: 16)
        nameLabel.alignment = .center
        nameLabel.font = NSFont.systemFont(ofSize: 10)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        view.addSubview(nameLabel)
    }

    func configure(with url: URL) {
        fileURL = url
        // Try loading the actual image content for thumbnails;
        // fall back to the Finder icon for non-image files.
        if let image = NSImage(contentsOf: url) {
            // Scale to fit the icon area while preserving aspect ratio.
            let size = NSSize(width: 48, height: 48)
            let thumb = NSImage(size: size)
            thumb.lockFocus()
            let ratio = min(
                size.width / image.size.width,
                size.height / image.size.height
            )
            let scaled = NSSize(
                width: image.size.width * ratio,
                height: image.size.height * ratio
            )
            let origin = NSPoint(
                x: (size.width - scaled.width) / 2,
                y: (size.height - scaled.height) / 2
            )
            image.draw(in: NSRect(origin: origin, size: scaled))
            thumb.unlockFocus()
            iconView.image = thumb
        } else {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        nameLabel.stringValue = url.lastPathComponent
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when files are dropped into a FileBoxView.
    /// `userInfo` contains the `URL` under the `"url"` key.
    static let fileBoxDidReceiveFiles = Notification.Name("FileBoxDidReceiveFiles")
}
