//
//  EditorBridge.swift
//  FlashboxEditor
//
//  Handles Swift <-> JavaScript communication with the CodeMirror 6 editor
//  loaded inside a WKWebView. Bridges the gap between Flashbox's EditorCommand
//  model and MarkEdit's web module function calls.
//

import WebKit
import FlashboxCore

// MARK: - JS → Swift Message Handler

/// Receives bridge messages posted from the CodeMirror 6 JavaScript context
/// via `window.webkit.messageHandlers.bridge.postMessage(jsonString)`.
///
/// Messages follow MarkEdit's convention:
/// ```json
/// { "moduleName": "core", "methodName": "notifyViewDidUpdate", "parameters": "{...}" }
/// ```
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler {

    // MARK: - Properties

    private weak var webView: WKWebView?

    /// Called whenever the editor content is modified by the user.
    /// The closure receives the full current Markdown text.
    var onContentChanged: ((String) -> Void)?

    /// Called when the editor finishes its initial load sequence.
    var onEditorReady: (() -> Void)?

    // MARK: - Init

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "bridge",
              let body = message.body as? [String: Any],
              let moduleName = body["moduleName"] as? String,
              let methodName = body["methodName"] as? String else {
            return
        }

        // The editor window finished loading and initializing
        if moduleName == "core", methodName == "notifyWindowDidLoad" {
            onEditorReady?()
            return
        }

        // The editor content was updated by user interaction
        if moduleName == "core", methodName == "notifyViewDidUpdate" {
            if let paramsString = body["parameters"] as? String,
               let paramsData = paramsString.data(using: .utf8) {
                struct ViewUpdate: Decodable {
                    let contentEdited: Bool
                    let compositionEnded: Bool
                    let isDirty: Bool
                }
                if let update = try? JSONDecoder().decode(ViewUpdate.self, from: paramsData),
                   update.contentEdited {
                    getEditorText { [weak self] text in
                        if let text {
                            self?.onContentChanged?(text)
                        }
                    }
                }
            }
            return
        }
    }

    // MARK: - Swift → JS Communication

    /// Focus the CodeMirror editor (show cursor, accept keyboard input).
    func focus() {
        webView?.evaluateJavaScript("window.editor.contentDOM.focus()")
    }

    /// Resets the editor content to the given Markdown string.
    func resetEditor(text: String) {
        let jsonText = encodeJSON(text)
        let script = "typeof webModules === 'object' ? webModules.core.resetEditor({\"text\":\(jsonText)}) : undefined"
        webView?.evaluateJavaScript(script)
    }

    /// Retrieves the current editor text (Markdown) from CodeMirror 6.
    /// Uses `callAsyncJavaScript` because the JS function is `async`.
    func getEditorText(completion: @escaping (String?) -> Void) {
        webView?.callAsyncJavaScript(
            "return await webModules.core.getEditorText()",
            arguments: [:],
            in: nil,
            in: .page
        ) { result in
            switch result {
            case .success(let value):
                completion(value as? String)
            case .failure:
                completion(nil)
            }
        }
    }

    /// Maps a Flashbox `EditorCommand` to the corresponding MarkEdit
    /// `webModules.format.*` or `webModules.core.*` function call.
    func executeCommand(command: EditorCommand) {
        let script: String
        switch command {
        case .bold:
            script = "webModules.format.toggleBold()"
        case .italic:
            script = "webModules.format.toggleItalic()"
        case .strikethrough:
            script = "webModules.format.toggleStrikethrough()"
        case .heading:
            script = "webModules.format.toggleHeading({\"level\":1})"
        case .unorderedList:
            script = "webModules.format.toggleBullet()"
        case .orderedList:
            script = "webModules.format.toggleNumbering()"
        case .taskList:
            script = "webModules.format.toggleTodo()"
        case .blockquote:
            script = "webModules.format.toggleBlockquote()"
        case .codeBlock:
            script = "webModules.format.insertCodeBlock()"
        case .link:
            let titleJSON = encodeJSON("link text")
            let urlJSON = encodeJSON("https://")
            script = "webModules.format.insertHyperLink({\"title\":\(titleJSON),\"url\":\(urlJSON),\"prefix\":null})"
        case .image:
            let titleJSON = encodeJSON("image alt")
            let urlJSON = encodeJSON("https://")
            script = "webModules.format.insertHyperLink({\"title\":\(titleJSON),\"url\":\(urlJSON),\"prefix\":\"!\"})"
        case .horizontalRule:
            script = "webModules.format.insertHorizontalRule()"
        case .clearAll:
            script = "webModules.core.resetEditor({\"text\":\"\"})"
        }

        let guarded = "typeof webModules === 'object' ? \(script) : undefined"
        webView?.evaluateJavaScript(guarded)
    }
}

// MARK: - Helpers

/// Returns a JSON-encoded string suitable for embedding in a JavaScript expression.
private func encodeJSON(_ string: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed),
          let json = String(data: data, encoding: .utf8) else {
        return "\"\""
    }
    return json
}
