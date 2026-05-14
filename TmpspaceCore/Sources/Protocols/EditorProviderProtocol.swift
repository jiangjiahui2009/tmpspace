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
/// Implemented by TmpspaceEditor.
@MainActor
public protocol EditorProviderProtocol: AnyObject, Sendable {
    /// Create and return an NSView containing the full editor (WKWebView + CodeMirror 6)
    /// for the specified panel.
    func createEditorView(for panelId: UUID) -> NSView

    /// Get the current Markdown content of the editor.
    func getContent(for panelId: UUID) -> String

    /// Set the editor's Markdown content (e.g. restoring from storage).
    func setContent(for panelId: UUID, content: String)

    /// Append text to the end of the editor and move the cursor after it.
    /// Inserts a newline separator if the current content doesn't end with one.
    func appendContent(for panelId: UUID, content: String)

    /// Execute a formatting or editing command on the editor.
    func executeCommand(for panelId: UUID, command: EditorCommand)

    /// Apply display settings (theme, font, line numbers, etc.) to an editor panel.
    ///
    /// Called when settings change in the preferences window, and when a new
    /// editor is created so it starts with the user's preferred appearance.
    func applySettings(_ settings: EditorDisplaySettings, for panelId: UUID)

    /// Tear down and release the editor resources for the given panel.
    func destroyEditor(for panelId: UUID)
}
