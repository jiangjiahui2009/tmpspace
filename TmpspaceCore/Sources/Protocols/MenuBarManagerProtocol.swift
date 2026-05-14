import Foundation

/// Protocol for managing the menu bar presence and panel lifecycle.
/// Implemented by TmpspaceMenuBar.
@MainActor
public protocol MenuBarManagerProtocol: AnyObject {
    /// Show or hide all panels (toggled by menu bar icon click or global shortcut).
    func togglePanels()

    /// Show all panels.
    func showPanels()

    /// Hide all panels without destroying them.
    func hidePanels()

    /// Create a new panel and return its model.
    func createNewPanel() -> PanelModel

    /// Delete a panel by ID, removing its editor and storage.
    func deletePanel(id: UUID)

    /// The currently managed panels.
    var panels: [PanelModel] { get }

    /// Is the menu bar setup complete?
    var isMenuBarReady: Bool { get }
}
