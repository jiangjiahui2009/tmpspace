import AppKit

/// Commands that the editor supports (sent from Swift to JS/CodeMirror 6).
public enum EditorCommand: String, CaseIterable {
    case bold
    case italic
    case strikethrough
    case heading
    case unorderedList
    case orderedList
    case taskList        // - [ ] checkbox list
    case blockquote
    case codeBlock
    case link
    case image
    case horizontalRule
    case clearAll        // Clear entire editor content
}

/// Protocol for providing a Markdown editor view to be embedded in a panel.
/// Implemented by FlashboxEditor.
@MainActor
public protocol EditorProviderProtocol: AnyObject, Sendable {
    /// Create and return an NSView containing the full editor (WKWebView + CodeMirror 6)
    /// for the specified panel.
    func createEditorView(for panelId: UUID) -> NSView

    /// Get the current Markdown content of the editor.
    func getContent(for panelId: UUID) -> String

    /// Set the editor's Markdown content (e.g. restoring from storage).
    func setContent(for panelId: UUID, content: String)

    /// Execute a formatting or editing command on the editor.
    func executeCommand(for panelId: UUID, command: EditorCommand)

    /// Tear down and release the editor resources for the given panel.
    func destroyEditor(for panelId: UUID)
}
