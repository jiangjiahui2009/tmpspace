//
//  EditorViewController.swift
//  FlashboxEditor
//
//  NSViewController subclass that manages a WKWebView containing CodeMirror 6,
//  loaded from MarkEdit's compiled CoreEditor bundle. One instance per editor panel.
//

import AppKit
import WebKit
import FlashboxCore

// MARK: - Editor Config (minimal)

/// A minimal subset of MarkEdit's `EditorConfig` containing only the properties
/// required by the CoreEditor JavaScript bundle at startup.
private struct MinimalEditorConfig: Encodable {
    let text: String
    let theme: String
    let fontFace: FontFace
    let fontSize: Double
    let showLineNumbers: Bool
    let showActiveLineIndicator: Bool
    let invisiblesBehavior: String
    let readOnlyMode: Bool
    let typewriterMode: Bool
    let focusMode: Bool
    let lineWrapping: Bool
    let lineHeight: Double
    let suggestWhileTyping: Bool
    let standardDirectories: [String: String]
    let defaultLineBreak: String?
    let tabKeyBehavior: Int?
    let indentUnit: String?
    let autoCharacterPairs: Bool
    let indentBehavior: String
    let headerFontSizeDiffs: [Double]?
    let visibleWhitespaceCharacter: String?
    let visibleLineBreakCharacter: String?
    let searchNormalizers: [String: String]?

    struct FontFace: Encodable {
        let family: String
        let weight: String?
        let style: String?
    }
}

// MARK: - Chunck Loader (URL Scheme Handler)

/// Serves static JS/CSS/font assets from the CoreEditor dist/chunks directory
/// using a custom `chunk-loader` URL scheme, matching how MarkEdit loads editor chunks.
private final class ChunkLoader: NSObject, WKURLSchemeHandler {

    static let scheme = "chunk-loader"

    /// Filesystem path to the `CoreEditor/dist/` directory.
    private let distPath: String

    init(distPath: String) {
        self.distPath = distPath
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let host = url.host(),
              host == "chunks" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let relativePath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let filePath = "\(distPath)/chunks/\(relativePath)"

        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = Self.mimeTypes[url.pathExtension] ?? "application/octet-stream"

        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: fileData.count,
            textEncodingName: nil
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(fileData)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // no-op
    }

    private static let mimeTypes: [String: String] = [
        "js": "text/javascript",
        "css": "text/css",
        "woff2": "font/woff2",
        "html": "text/html",
    ]
}

// MARK: - Editor WebView

/// A WKWebView subclass that accepts first responder so the CodeMirror 6
/// editor can receive keyboard focus and display a cursor.
private final class EditorWebView: WKWebView, WKNavigationDelegate {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Only do the activation-policy dance when the app is not already active.
        // Calling setActivationPolicy(.accessory) while active would deactivate us.
        let needsActivation = !NSApp.isActive
        if needsActivation {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeFirstResponder(self)
        // Focus the CodeMirror contentDOM so the cursor appears.
        evaluateJavaScript("window.editor?.contentDOM?.focus()")
        if needsActivation {
            NSApp.setActivationPolicy(.accessory)
        }
        super.mouseDown(with: event)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded; editor initialization will fire onEditorReady via the bridge.
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        editorLog("EditorWebView — didFail navigation: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        editorLog("EditorWebView — didFailProvisionalNavigation: \(error.localizedDescription)")
    }
}

// MARK: - WebKit SPI

private protocol WebKitConfigSPI: NSObject {}
extension WKWebViewConfiguration: WebKitConfigSPI {}
extension WKPreferences: WebKitConfigSPI {}

extension WebKitConfigSPI {
    @discardableResult
    func setBoolValue(_ value: Bool, forSelector selectorName: String) -> Bool {
        let selector = sel_getUid(selectorName)
        guard responds(to: selector) else {
            return false
        }
        let setValue = unsafeBitCast(
            method(for: selector),
            to: (@convention(c) (NSObject, Selector, Bool) -> Void).self
        )
        setValue(self, selector, value)
        return true
    }
}

/// Logger bridge — since EditorViewController is in FlashboxEditor and
/// DebugLog is in FlashboxMenuBar, we log via a simple file write.
private func editorLog(_ msg: String) {
    guard let data = ("\(Date()) [Editor] \(msg)\n").data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/flashbox-debug.log")
    if let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
        try? h.close()
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Editor View Controller

/// Manages the lifecycle of a single CodeMirror 6 editor instance embedded in a WKWebView.
///
/// Implements `EditorProviderProtocol` so that FlashboxMenuBar panels can
/// request editor views, get/set content, execute formatting commands,
/// and tear down editors without knowledge of the underlying WebKit machinery.
@MainActor
public final class EditorViewController: NSViewController, EditorProviderProtocol {

    // MARK: - Callbacks

    /// Invoked whenever the user edits the Markdown content.
    /// The `UUID` parameter identifies which panel the content belongs to.
    public var onContentChanged: ((UUID, String) -> Void)?

    // MARK: - Private Properties

    /// Filesystem path to the compiled `CoreEditor/dist/` directory.
    private let distPath: String

    /// Per-panel editor state.
    private var editorStates: [UUID: EditorState] = [:]

    /// Cached content for synchronous `getContent` calls.
    private var lastKnownContent: [UUID: String] = [:]

    private struct EditorState {
        let webView: WKWebView
        let bridge: EditorBridge
    }

    // MARK: - Init

    /// - Parameter distPath: Absolute filesystem path to the `CoreEditor/dist/`
    ///   directory containing `index.html` and the `chunks/` subdirectory.
    public init(distPath: String) {
        self.distPath = distPath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - EditorProviderProtocol

    public func createEditorView(for panelId: UUID) -> NSView {
        // If an editor already exists for this panel, return its view.
        if let existing = editorStates[panelId] {
            return existing.webView
        }

        let (webView, bridge) = makeEditorWebView(panelId: panelId)
        editorStates[panelId] = EditorState(webView: webView, bridge: bridge)
        return webView
    }

    public func getContent(for panelId: UUID) -> String {
        return lastKnownContent[panelId] ?? ""
    }

    public func setContent(for panelId: UUID, content: String) {
        guard let state = editorStates[panelId] else { return }
        lastKnownContent[panelId] = content
        state.bridge.resetEditor(text: content)
    }

    public func executeCommand(for panelId: UUID, command: EditorCommand) {
        guard let state = editorStates[panelId] else { return }
        state.bridge.executeCommand(command: command)
    }

    public func destroyEditor(for panelId: UUID) {
        guard let state = editorStates.removeValue(forKey: panelId) else { return }
        state.webView.stopLoading()
        state.webView.removeFromSuperview()
    }

    // MARK: - Builder

    /// Creates and configures a WKWebView that loads the CodeMirror 6 editor.
    private func makeEditorWebView(panelId: UUID) -> (WKWebView, EditorBridge) {
        // 1. Message handler / user content controller
        let controller = WKUserContentController()

        // 2. Web view configuration
        let config = WKWebViewConfiguration()
        config.userContentController = controller

        // Disable CORS so ES modules loaded via custom URL schemes are not blocked.
        // WKWebView enforces CORS for <script type="module"> by default, and our
        // custom chunk-loader scheme handler returns plain URLResponse (no CORS headers).
        config.preferences.setBoolValue(false, forSelector: "_setWebSecurityEnabled:")

        // 3. Register the chunk-loader URL scheme handler for loading JS/CSS/font assets.
        let chunkLoader = ChunkLoader(distPath: distPath)
        config.setURLSchemeHandler(chunkLoader, forURLScheme: ChunkLoader.scheme)

        // 4. Create the WKWebView (use EditorWebView to accept first responder)
        let webView = EditorWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = webView
        webView.allowsMagnification = true
        // Debug: set a visible background to confirm the WKWebView renders
        webView.setValue(true, forKey: "drawsBackground")

        // 5. Bridge (handles JS <-> Swift communication)
        let bridge = EditorBridge(webView: webView)
        // The bridge must be registered AFTER the webView is created, but
        // WKUserContentController.addScriptMessageHandler adds a strong
        // reference, so we use a wrapper to avoid retain cycles.
        controller.add(ScriptMessageHandlerWrapper(bridge: bridge), contentWorld: .page, name: "bridge")

        // Wire up content-change forwarding.
        bridge.onContentChanged = { [weak self] text in
            self?.lastKnownContent[panelId] = text
            self?.onContentChanged?(panelId, text)
        }

        bridge.onEditorReady = { [weak bridge] in
            bridge?.resetEditor(text: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                bridge?.focus()
            }
        }

        // 6. Load the real CodeMirror 6 editor.
        editorLog("Loading CoreEditor HTML...")
        loadEditorHTML(into: webView)
        editorLog("CoreEditor HTML load initiated")

        return (webView, bridge)
    }

    /// Reads the `dist/index.html`, replaces placeholders, and loads it into the WebView.
    private func loadEditorHTML(into webView: WKWebView) {
        let indexPath = "\(distPath)/index.html"
        guard let rawHTML = try? String(contentsOfFile: indexPath, encoding: .utf8) else {
            fatalError("Missing CoreEditor dist/index.html at path: \(indexPath)")
        }

        // Build a minimal editor config matching what the CoreEditor JS expects.
        let config = MinimalEditorConfig(
            text: "",
            theme: "system",
            fontFace: .init(family: "system-ui", weight: nil, style: nil),
            fontSize: 14,
            showLineNumbers: false,
            showActiveLineIndicator: false,
            invisiblesBehavior: "never",
            readOnlyMode: false,
            typewriterMode: false,
            focusMode: false,
            lineWrapping: true,
            lineHeight: 1.6,
            suggestWhileTyping: false,
            standardDirectories: [:],
            defaultLineBreak: nil,
            tabKeyBehavior: nil,
            indentUnit: nil,
            autoCharacterPairs: true,
            indentBehavior: "paragraph",
            headerFontSizeDiffs: nil,
            visibleWhitespaceCharacter: nil,
            visibleLineBreakCharacter: nil,
            searchNormalizers: nil
        )

        let configJSON: String
        if let data = try? JSONEncoder().encode(config),
           let json = String(data: data, encoding: .utf8) {
            configJSON = json
        } else {
            configJSON = "{}"
        }

        let html = rawHTML
            .replacingOccurrences(of: "/chunk-loader/", with: "\(ChunkLoader.scheme)://")
            .replacingOccurrences(of: "\"{{EDITOR_CONFIG}}\"", with: configJSON)
            .replacingOccurrences(of: "\"{{USER_SETTINGS}}\"", with: "{}")

        webView.loadHTMLString(html, baseURL: URL(string: "http://localhost/"))
    }
}

// MARK: - Script Message Handler Wrapper

/// Wraps an `EditorBridge` to break the retain cycle introduced by
/// `WKUserContentController.addScriptMessageHandler(_:contentWorld:name:)`,
/// which holds a strong reference to its handler.
private final class ScriptMessageHandlerWrapper: NSObject, WKScriptMessageHandler {

    private weak var bridge: EditorBridge?

    init(bridge: EditorBridge) {
        self.bridge = bridge
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        bridge?.userContentController(userContentController, didReceive: message)
    }
}
