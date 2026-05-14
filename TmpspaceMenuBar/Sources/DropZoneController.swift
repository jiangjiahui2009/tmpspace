//
//  DropZoneController.swift
//  TmpspaceMenuBar
//
//  Manages a floating panel that sits below the menu bar icon and appears
//  whenever the user starts dragging files (system-wide). Dropped files
//  are saved to the file box. Only active when no editor panels are visible.
//

import AppKit
import TmpspaceCore

/// Monitors the system drag pasteboard and shows a drop zone panel below
/// the menu bar icon when the user drags files anywhere on screen.
@MainActor
final class DropZoneController {

    // MARK: - Properties

    private let panel: NSPanel
    private let dropView: DropZoneView
    private var hideWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?

    /// Called to check whether panels are currently visible.
    var arePanelsVisible: (() -> Bool)?

    // Track the drag pasteboard change count to detect new drags.
    private var lastDragChangeCount: Int = NSPasteboard(name: .drag).changeCount
    // When the last change was detected (for staleness timeout).
    private var lastChangeTime: Date = Date()
    // Poll iteration counter (for heartbeat logging).
    private var pollCount = 0
    private var mouseUpMonitor: Any?

    // MARK: - Sizes

    private static let idleSize   = NSSize(width: 140, height: 6)
    private static let activeSize = NSSize(width: 140, height: 64)

    // MARK: - Init

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.idleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.hasShadow = false
        panel.isMovable = false
        panel.alphaValue = 0

        dropView = DropZoneView(frame: NSRect(origin: .zero, size: Self.idleSize))
        dropView.translatesAutoresizingMaskIntoConstraints = true
        dropView.autoresizingMask = [.width, .height]

        dropView.onFileDrop = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }
        dropView.onDragEnded = { [weak self] in
            self?.collapseToIdle()
        }

        panel.contentView = dropView

        startPollingDragPasteboard()
    }

    // MARK: - Drag pasteboard polling

    /// Poll the system drag pasteboard every 0.15s. When a new file drag
    /// is detected, expand the drop zone. When the drag ends, collapse it.
    private func startPollingDragPasteboard() {
        DebugLog.log("DropZone — starting poll timer")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkDragPasteboard()
            }
        }
        // Fire immediately to capture initial state.
        Task { @MainActor [weak self] in
            self?.checkDragPasteboard()
        }
    }

    private func checkDragPasteboard() {
        pollCount += 1
        let dragPb = NSPasteboard(name: .drag)
        let count = dragPb.changeCount

        // Log every 20 polls (~3s) for heartbeat.
        if pollCount % 20 == 1 {
            DebugLog.log("DropZone — poll heartbeat #\(pollCount), changeCount=\(count), last=\(lastDragChangeCount), isActive=\(dropView.isActive)")
        }

        let changed = count != lastDragChangeCount
        if changed {
            lastDragChangeCount = count
            lastChangeTime = Date()
        }

        // Staleness fallback: if active and no pasteboard change for > 2s
        // AND the pasteboard no longer has files, force collapse.
        if dropView.isActive, Date().timeIntervalSince(lastChangeTime) > 2.0 {
            if !dragPb.canReadObject(forClasses: [NSURL.self], options: nil) {
                DebugLog.log("DropZone — pasteboard stale for > 2s and no files, force collapsing")
                collapseToIdle()
                return
            }
            // Still has files — drag ongoing, reset the timer.
            lastChangeTime = Date()
            return
        }

        guard changed else { return }

        // Check if files are being dragged.
        let canRead = dragPb.canReadObject(forClasses: [NSURL.self], options: nil)
        guard canRead else {
            if dropView.isActive {
                scheduleCollapse()
            }
            return
        }

        // Files are being dragged — show the drop zone if panels are hidden.
        guard arePanelsVisible?() == false else { return }

        if !dropView.isActive {
            expandPanel()
        }

        // Reset the collapse timer — drag is still active.
        cancelHide()
    }

    // MARK: - Expand / Collapse

    private func expandPanel() {
        cancelHide()

        // Start listening for mouse-up to detect drag end reliably.
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.collapseToIdle()
                }
            }
        }

        let currentOrigin = panel.frame.origin
        let fixedOrigin = NSPoint(
            x: currentOrigin.x,
            y: currentOrigin.y - (Self.activeSize.height - Self.idleSize.height)
        )

        panel.hasShadow = true
        panel.setFrame(NSRect(origin: fixedOrigin, size: Self.activeSize), display: true)
        dropView.isActive = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        DebugLog.log("DropZone — expanded to active")
    }

    private func collapseToIdle() {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        // Remove the mouse-up monitor.
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }

        guard dropView.isActive else { return }

        // Immediately mark inactive so polling won't re-expand during animation.
        dropView.isActive = false

        let currentOrigin = panel.frame.origin
        let idleOrigin = NSPoint(
            x: currentOrigin.x,
            y: currentOrigin.y + (Self.activeSize.height - Self.idleSize.height)
        )

        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.05
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.panel.setFrame(NSRect(origin: idleOrigin, size: Self.idleSize), display: false)
                self.panel.hasShadow = false
            }
        }

        DebugLog.log("DropZone — collapsed to idle")
    }

    func scheduleCollapse() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseToIdle()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    // MARK: - Positioning

    func reposition(below screenFrame: NSRect) {
        let size = panel.frame.size
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY - size.height

        var origin = NSPoint(x: x, y: y)

        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(screenFrame) }) {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
            if origin.y < visible.minY {
                origin.y = screenFrame.maxY
            }
        }

        panel.setFrameOrigin(origin)
    }

    func ensureVisible() {
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    /// Enable or disable drag monitoring. When disabled, the panel collapses
    /// and polling stops.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            if pollTimer == nil {
                startPollingDragPasteboard()
            }
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            if dropView.isActive {
                collapseToIdle()
            }
            panel.orderOut(nil)
        }
        DebugLog.log("DropZone — setEnabled(\(enabled))")
    }

    // MARK: - File handling

    private func handleDroppedFiles(_ urls: [URL]) {
        let manager = FileBoxManager()
        for url in urls {
            _ = manager.addFile(url)
        }
        collapseToIdle()
        NotificationCenter.default.post(
            name: .tmpspaceDropZoneDidReceiveFiles,
            object: nil
        )
    }
}

// MARK: - Drop zone content view

private final class DropZoneView: NSView {

    var isActive: Bool = false {
        didSet {
            iconView.isHidden = !isActive
            label.isHidden = !isActive
            needsDisplay = true
        }
    }

    var onFileDrop: (([URL]) -> Void)?
    /// Called when the drag session ends (drop or cancel), so the panel can collapse.
    var onDragEnded: (() -> Void)?

    private let iconView: NSImageView
    private let label: NSTextField

    override init(frame frameRect: NSRect) {
        iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "tray.and.arrow.up.fill",
                                  accessibilityDescription: "拖拽存入")
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isHidden = true

        label = NSTextField(labelWithString: "拖拽存入临时空间")
        label.alignment = .center
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true

        super.init(frame: frameRect)
        wantsLayer = true

        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor: NSColor = isDark
            ? NSColor(white: 0.18, alpha: 0.78)
            : NSColor(white: 0.98, alpha: 0.78)
        bgColor.setFill()

        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.fill()

        let borderColor: NSColor = isDark
            ? NSColor(white: 1.0, alpha: 0.3)
            : NSColor(white: 0.0, alpha: 0.25)
        borderColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
        else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil
        ) as? [URL], !urls.isEmpty else {
            return false
        }
        onFileDrop?(urls)
        return true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragEnded?()
    }
}
