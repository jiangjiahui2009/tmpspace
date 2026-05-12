import AppKit

/// A transparent overlay view that sits on top of the NSStatusBarButton
/// and reliably detects left-clicks vs. right-clicks.
final class StatusBarClickView: NSView {

    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    /// Weak reference to the status item so we can show its menu later.
    weak var statusItem: NSStatusItem?

    // MARK: - Click handling

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
