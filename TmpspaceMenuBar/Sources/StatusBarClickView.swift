import AppKit

/// A custom view for the NSStatusItem that detects left-clicks, right-clicks,
/// and file drag-and-drop. Used as `statusItem.view` instead of the default
/// NSStatusBarButton.
final class StatusBarClickView: NSView {

    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    /// Weak reference to the status item so we can show its menu later.
    weak var statusItem: NSStatusItem?

    /// The NSImageView that displays the status bar icon.
    var imageView: NSImageView?

    // MARK: - Drag callbacks

    /// Called when files are dragged into this view.
    /// Return `true` to accept the drag, `false` to reject.
    var onDragEntered: (() -> Bool)?

    /// Called when the drag exits this view.
    var onDragExited: (() -> Void)?

    /// Called when files are dropped directly onto this view.
    var onFileDrop: (([URL]) -> Bool)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Click handling

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(sender) else { return [] }
        let accepted = onDragEntered?() ?? false
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = readFileURLs(sender) else { return false }
        return onFileDrop?(urls) ?? false
    }

    // MARK: - Helpers

    private func hasFileURLs(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    private func readFileURLs(_ sender: any NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    }
}
