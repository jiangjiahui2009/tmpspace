import Foundation
import FlashboxCore

/// Manages debounced auto-save per panel ID using Swift Concurrency.
///
/// Each panel gets its own debounce timer so that rapid changes to one panel
/// do not cancel pending saves for another.
///
/// Implemented as a Swift `actor` to guarantee thread safety for the
/// pending-task dictionary without external locking.
actor AutoSaveManager {

    // MARK: - Private state

    /// Pending debounce tasks keyed by panel identifier.
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]

    /// Debounce duration in nanoseconds.
    private let debounceNs: UInt64

    // MARK: - Init

    /// - Parameter debounceMs: How many milliseconds to wait after the most recent
    ///   change before calling `save`.
    init(debounceMs: UInt64) {
        self.debounceNs = debounceMs * 1_000_000
    }

    // MARK: - Public API

    /// Schedule a debounced save for a panel.
    ///
    /// If a pending save already exists for `panelId` it is cancelled first,
    /// guaranteeing that only the most recent state is persisted.
    ///
    /// - Parameters:
    ///   - panelId: The panel whose content changed.
    ///   - panel: Snapshot of the panel at the time content changed.
    ///   - save: Closure that performs the actual persistence. Called once the
    ///     debounce interval has elapsed without a subsequent change.
    func scheduleSave(
        panelId: UUID,
        panel: PanelModel,
        save: @escaping @Sendable (PanelModel) async throws -> Void
    ) {
        // Cancel the previously pending task for this panel (if any).
        pendingTasks[panelId]?.cancel()

        let debounce = debounceNs
        let capturedPanel = panel
        let capturedSave = save

        let task = Task { @Sendable in
            do {
                try await Task.sleep(nanoseconds: debounce)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            try? await capturedSave(capturedPanel)
        }

        pendingTasks[panelId] = task
    }

    /// Cancel the pending auto-save for a single panel (e.g. when the panel is deleted).
    func cancelSave(panelId: UUID) {
        pendingTasks[panelId]?.cancel()
        pendingTasks[panelId] = nil
    }

    /// Cancel **all** pending auto-save timers.
    ///
    /// Called on app termination so that `saveAllPanels` can do a single
    /// synchronous write instead.
    func flushAll() {
        for (_, task) in pendingTasks {
            task.cancel()
        }
        pendingTasks.removeAll()
    }

    deinit {
        for (_, task) in pendingTasks {
            task.cancel()
        }
    }
}
