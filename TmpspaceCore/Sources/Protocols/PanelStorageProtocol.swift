import Foundation

/// Protocol for panel content persistence (auto-save, load, delete).
/// Implemented by TmpspaceStorage.
public protocol PanelStorageProtocol: AnyObject, Sendable {
    /// Persist a full panel snapshot (called on panel creation and major state changes).
    func savePanel(_ panel: PanelModel) async throws

    /// Load all persisted panels on app launch.
    func loadAllPanels() async throws -> [PanelModel]

    /// Delete a panel's persisted data permanently.
    func deletePanel(id: UUID) async throws

    /// Called on each content change event. Implementation should debounce
    /// writes (Constants.autoSaveDebounceMs) before persisting.
    func panelContentDidChange(id: UUID, content: String) async

    /// Persist all panels — called on app termination.
    func saveAllPanels(_ panels: [PanelModel]) async throws
}
