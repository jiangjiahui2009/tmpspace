//
//  EditorBridge.swift
//  TmpspaceEditor
//
//  Handles Swift <-> JavaScript communication with the CodeMirror 6 editor
//  loaded inside a WKWebView. Bridges the gap between Tmpspace's EditorCommand
//  model and MarkEdit's web module function calls.
//

import AppKit
import WebKit
import TmpspaceCore

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

    /// Called when the user Cmd+clicks a task list checkbox.
    /// The `Bool` is `true` when the checkbox is now checked, `false` when unchecked.
    var onTaskToggled: ((Bool) -> Void)?

    /// Called when files are dragged into the editor area.
    var onDragEntered: (() -> Void)?

    /// Called when the file drag leaves the editor area.
    var onDragLeft: (() -> Void)?

    /// Called when files are dropped onto the editor.
    /// Each item contains the file name, MIME type, size, and base64-encoded data URL.
    var onFilesDropped: (([FileDropItem]) -> Void)?

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

        // The user toggled a task list checkbox via Cmd+click.
        if moduleName == "core", methodName == "notifyTaskToggled" {
            if let paramsString = body["parameters"] as? String,
               let paramsData = paramsString.data(using: .utf8) {
                struct TaskToggle: Decodable {
                    let checked: Bool
                }
                if let toggle = try? JSONDecoder().decode(TaskToggle.self, from: paramsData) {
                    onTaskToggled?(toggle.checked)
                }
            }
            return
        }

        // Files were dragged into the editor area.
        if moduleName == "core", methodName == "notifyDragEntered" {
            editorLog("EditorBridge — received notifyDragEntered")
            onDragEntered?()
            return
        }

        // Files were dragged out of the editor area.
        if moduleName == "core", methodName == "notifyDragLeft" {
            editorLog("EditorBridge — received notifyDragLeft")
            onDragLeft?()
            return
        }

        // Drag handler JS was injected successfully.
        if moduleName == "core", methodName == "notifyDragHandlerInstalled" {
            editorLog("EditorBridge — drag handler JS installed OK")
            return
        }

        // Diagnostic: gutter measurements
        if moduleName == "core", methodName == "notifyDiagnostic" {
            editorLog("notifyDiagnostic received, body=\(body)")
            if let paramsString = body["parameters"] as? String {
                editorLog("notifyDiagnostic params=\(paramsString.prefix(200))")
                if let paramsData = paramsString.data(using: .utf8),
                   let obj = try? JSONDecoder().decode([String: String].self, from: paramsData),
                   let lines = obj["lines"] {
                    editorLog("GutterDiag:\n\(lines)")
                } else {
                    editorLog("notifyDiagnostic: failed to decode params")
                }
            } else {
                editorLog("notifyDiagnostic: parameters not a String")
            }
            return
        }

        // User pasted into the editor; read the native clipboard and insert.
        if moduleName == "core", methodName == "notifyPasteRequested" {
            handlePasteRequest()
            return
        }

        // Files were dropped onto the editor.
        if moduleName == "core", methodName == "notifyFilesDropped" {
            editorLog("EditorBridge — received notifyFilesDropped")
            if let paramsString = body["parameters"] as? String,
               let paramsData = paramsString.data(using: .utf8),
               let items = try? JSONDecoder().decode([FileDropItem].self, from: paramsData) {
                editorLog("EditorBridge — parsed \(items.count) FileDropItems")
                onFilesDropped?(items)
            }
            return
        }
    }

    // MARK: - Swift → JS Communication

    /// Focus the CodeMirror editor (show cursor, accept keyboard input).
    func focus() {
        webView?.evaluateJavaScript("window.editor.contentDOM.focus()")
    }

    /// Resets the editor content to the given Markdown string, then moves the
    /// cursor to the end of the document.
    func resetEditor(text: String) {
        let jsonText = encodeJSON(text)
        let script = """
        (function() {
            if (typeof webModules === 'object') {
                webModules.core.resetEditor({"text":\(jsonText)});
            }
            var view = window.editor;
            if (view) {
                var len = view.state.doc.length;
                view.dispatch({selection: {anchor: len, head: len}});
                view.contentDOM.focus();
            }
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Append text to the end of the editor and move the cursor after it.
    func appendTextToEnd(_ text: String) {
        let jsonText = encodeJSON(text)
        let script = """
        (function() {
            var view = window.editor;
            if (!view) return;
            var doc = view.state.doc;
            var insertPos = doc.length;
            var insertText = \(jsonText);
            var needNewline = insertPos > 0 && doc.sliceString(insertPos - 1, insertPos) !== '\\n';
            if (needNewline) { insertText = '\\n' + insertText; }
            view.dispatch({
                changes: {from: insertPos, to: insertPos, insert: insertText},
                selection: {anchor: insertPos + insertText.length}
            });
            view.contentDOM.focus();
        })()
        """
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

    // MARK: - Config bridge methods

    /// Set the syntax highlighting theme.
    func setTheme(_ name: String) {
        let json = encodeJSON(name)
        let script = "typeof webModules === 'object' ? webModules.config.setTheme({name:\(json)}) : undefined"
        webView?.evaluateJavaScript(script)
    }

    /// Inject CSS fixes that must run **after** CodeMirror's own stylesheet has loaded.
    /// Called from `onEditorReady` so our rules always come last in the cascade.
    func injectStyleFixes() {
        let script = """
        (function(){
        var s=document.getElementById('ts-fixes');
        if(!s){s=document.createElement('style');s.id='ts-fixes';document.head.appendChild(s);}
        s.textContent='.cm-specialChar { opacity: 0 !important; }';
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Diagnostic: log computed heights and positions of gutter elements vs
    /// content lines, so we can see exactly what's misaligned.
    func diagnoseGutter() {
        let script = """
        (function(){
        var gutters=document.querySelectorAll('.cm-lineNumbers .cm-gutterElement');
        var report=['--- Gutter Diag --- lines='+document.querySelectorAll('.cm-content .cm-line').length+' gutters='+gutters.length];
        for(var i=0;i<gutters.length;i++){
            var g=gutters[i];
            var r=g.getBoundingClientRect();
            report.push('g['+i+']: cls='+g.className+' txt='+(g.textContent||'')+
                ' top='+r.top.toFixed(1)+' h='+r.height.toFixed(1)+
                ' styH='+(g.style.height||'none')+' styPT='+(g.style.paddingTop||'none')+
                ' parent='+(g.parentElement?g.parentElement.className:'none'));
        }
        window.webkit.messageHandlers.bridge.postMessage(({
            moduleName:'core',
            methodName:'notifyDiagnostic',
            parameters:JSON.stringify({lines:report.join('\\n')})
        }));
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Remove phantom gutter elements that have no corresponding content line.
    /// These can appear inside .cm-lineNumbers with non-sequential text content
    /// (e.g. "9" when only 1 line exists), causing cumulative drift at that line.
    func cleanPhantomGutters() {
        let script = """
        (function(){
        var lineCount=document.querySelectorAll('.cm-content .cm-line').length;
        var gutters=document.querySelectorAll('.cm-lineNumbers .cm-gutterElement');
        // Only keep gutter elements whose text parse as a valid line number
        // in range [1, lineCount]
        var removed=0;
        for(var i=gutters.length-1;i>=0;i--){
            var n=parseInt(gutters[i].textContent,10);
            if(isNaN(n)||n<1||n>lineCount){
                gutters[i].remove();
                removed++;
            }
        }
        window.webkit.messageHandlers.bridge.postMessage(({
            moduleName:'core',
            methodName:'notifyDiagnostic',
            parameters:JSON.stringify({lines:'cleanPhantomGutters: removed '+removed+
                ' phantom elements, '+lineCount+' lines, '+
                document.querySelectorAll('.cm-lineNumbers .cm-gutterElement').length+' gutters remain'})
        }));
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Clear any stale inline styles on gutter elements, then force CodeMirror
    /// to re-measure. Called after DOM mutations to prevent the gutter from
    /// drifting when cached measurements survive document changes (e.g. after
    /// deleting lines and typing new ones).
    func injectGutterFix() {
        let lineHeight = EditorDisplaySettings.load().lineHeight
        let script = """
        (function(lh){
        var cssId='__ts_gutter_fix_css';
        if(!document.getElementById(cssId)){
            var s=document.createElement('style');
            s.id=cssId;
            s.textContent='.cm-line, .cm-gutterElement { line-height: '+lh+' !important; }';
            document.head.appendChild(s);
        }

        if(window.__tsGutterFixInstalled)return;
        window.__tsGutterFixInstalled=true;
        var content=document.querySelector('.cm-content');
        if(!content)return;
        var tm=null;
        var observer=new MutationObserver(function(){
            if(tm)clearTimeout(tm);
            tm=setTimeout(function(){
                var ed=window.editor;
                if(!ed)return;
                // Clear any inline height/padding that may have been set
                // by adjustActiveLineGutter / adjustGutter on stale elements.
                var gutters=document.querySelectorAll('.cm-lineNumbers .cm-gutterElement');
                for(var i=0;i<gutters.length;i++){
                    gutters[i].style.height='';
                    gutters[i].style.paddingTop='';
                }
                ed.requestMeasure();
            }, 20);
        });
        observer.observe(content,{childList:true,subtree:true,characterData:true});
        })(\(lineHeight))
        """
        webView?.evaluateJavaScript(script)
    }

    /// Force a complete gutter rebuild by toggling line numbers off and back on
    /// in the same synchronous tick. This destroys and recreates all gutter DOM
    /// elements, forcing fresh measurements — the same effect as the user toggling
    /// line numbers in Settings, which the user confirmed fixes the drift.
    /// No visual flicker because both dispatches are batched before the next paint.
    func forceGutterResync() {
        let script = """
        (function(){
        if(typeof webModules!=='object')return;
        if(!window.editor)return;
        webModules.config.setShowLineNumbers({enabled:false});
        webModules.config.setShowLineNumbers({enabled:true});
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Intercepts paste events inside the editor's content DOM and inserts plain
    /// text via the Async Clipboard API or a native bridge fallback, bypassing
    /// WKWebView's rich-text paste pipeline which collapses newlines into spaces.
    func injectPasteHandler() {
        let script = """
        (function(){
        if(window.__tsPasteInstalled)return;
        window.__tsPasteInstalled=true;
        document.addEventListener('paste',function(e){
            var cm=document.querySelector('.cm-content');
            if(!cm||!cm.contains(e.target))return;
            var view=window.editor;
            if(!view)return;

            // Always prevent WKWebView's default paste — it collapses newlines.
            e.preventDefault();
            e.stopPropagation();

            // Attempt 1: Async Clipboard API (returns raw system clipboard text).
            // paste is a user gesture, so readText() should work without a prompt.
            if(navigator.clipboard&&navigator.clipboard.readText){
                navigator.clipboard.readText().then(function(text){
                    if(text&&view.state){
                        view.dispatch(view.state.replaceSelection(text));
                        view.focus();
                    }
                }).catch(function(){
                    // Async Clipboard API failed — fall through to native bridge.
                    window.webkit.messageHandlers.bridge.postMessage(({
                        moduleName:'core',
                        methodName:'notifyPasteRequested',
                        parameters:'{}'
                    }));
                });
                return;
            }

            // Fallback: ask native side (NSPasteboard) for the clipboard text.
            window.webkit.messageHandlers.bridge.postMessage(({
                moduleName:'core',
                methodName:'notifyPasteRequested',
                parameters:'{}'
            }));
        },true);
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Reads the plain-text system clipboard and inserts it into the
    /// CodeMirror editor, bypassing WKWebView's rich-text paste pipeline.
    private func handlePasteRequest() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else {
            return
        }
        let jsonText = encodeJSON(text)
        let script = """
        (function(){
            var view=window.editor;
            if(!view)return;
            view.dispatch(view.state.replaceSelection(\(jsonText)));
            view.focus();
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Set the editor font face, weight, and style, then re-measure layout.
    func setFontFace(family: String, weight: String?, style: String?) {
        var fontFaceJSON = "{\"family\":\(encodeJSON(family))"
        if let weight { fontFaceJSON += ",\"weight\":\(encodeJSON(weight))" }
        if let style { fontFaceJSON += ",\"style\":\(encodeJSON(style))" }
        fontFaceJSON += "}"

        let script = """
        (function(){
        if(typeof webModules==='object')webModules.config.setFontFace({fontFace:\(fontFaceJSON)});
        if(window.editor)window.editor.requestMeasure();
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Set the editor font size in points, then re-measure layout.
    func setFontSize(_ size: Double) {
        let script = """
        (function(){
        if(typeof webModules==='object')webModules.config.setFontSize({fontSize:\(size)});
        if(window.editor)window.editor.requestMeasure();
        })()
        """
        webView?.evaluateJavaScript(script)
    }

    /// Toggle line numbers in the gutter.
    func setShowLineNumbers(_ enabled: Bool) {
        let script = "typeof webModules === 'object' ? webModules.config.setShowLineNumbers({enabled:\(enabled)}) : undefined"
        webView?.evaluateJavaScript(script)
    }

    /// Toggle the active-line highlight behind the cursor.
    func setShowActiveLineIndicator(_ enabled: Bool) {
        let script = "typeof webModules === 'object' ? webModules.config.setShowActiveLineIndicator({enabled:\(enabled)}) : undefined"
        webView?.evaluateJavaScript(script)
    }

    /// Force CodeMirror to re-measure layout (line heights, gutter positions).
    /// Call after font changes or when the gutter drifts from content lines.
    func remeasureLayout() {
        let script = "if(window.editor)window.editor.requestMeasure();"
        webView?.evaluateJavaScript(script)
    }

    /// Set the line-height multiplier (e.g. 1.4 / 1.6 / 1.8).
    ///
    /// After applying the config change we ask CodeMirror to re-measure layout
    /// so the gutter stays aligned with content lines.
    func setLineHeight(_ height: Double) {
        let script = """
        (function(lh){
        if(typeof webModules==='object')webModules.config.setLineHeight({lineHeight:lh});
        if(window.editor)window.editor.requestMeasure();
        })(\(height))
        """
        webView?.evaluateJavaScript(script)
    }

    // MARK: - Format / core commands

    /// Maps a Tmpspace `EditorCommand` to the corresponding MarkEdit
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

    // MARK: - Drag handler injection

    /// Injects a JavaScript drag-and-drop handler that shows a visual overlay
    /// when files are dragged over the editor. On drop, files are read via
    /// FileReader and sent back to Swift through the bridge as base64 data URLs.
    func injectDragHandler() {
        editorLog("EditorBridge.injectDragHandler — starting JS injection")

        // First, send a minimal test to verify evaluateJavaScript works.
        let testScript = """
        (function(){
            window.webkit.messageHandlers.bridge.postMessage(({
                moduleName:'core',
                methodName:'notifyDragHandlerInstalled',
                parameters:'{}'
            }));
        })();
        """
        webView?.evaluateJavaScript(testScript) { result, error in
            if let error {
                editorLog("EditorBridge.injectDragHandler — TEST JS error: \(error.localizedDescription)")
            } else {
                editorLog("EditorBridge.injectDragHandler — TEST JS completed, result=\(String(describing: result))")
            }
        }

        let script = """
(function() {
    console.log('[Tmpspace] drag handler IIFE executing');
    if (window.__tsDragInstalled) { console.log('[Tmpspace] already installed, bailing'); return; }
    window.__tsDragInstalled = true;

    var overlay = document.createElement('div');
    overlay.id = '__ts_drop_overlay';
    var label = document.createElement('div');
    label.textContent = '松开以存入临时空间';
    label.style.cssText = [
        'font-family:-apple-system,"SF Pro Text",sans-serif',
        'font-size:16px',
        'font-weight:600',
        'color:rgba(255,255,255,0.85)',
        'text-align:center',
        'pointer-events:none',
        'text-shadow:0 1px 3px rgba(0,0,0,0.3)',
    ].join(';');
    overlay.appendChild(label);
    overlay.style.cssText = [
        'position:fixed',
        'top:12px',
        'left:12px',
        'right:12px',
        'bottom:12px',
        'display:none',
        'z-index:999999',
        'pointer-events:none',
        'border:3px dashed rgba(255,255,255,0.5)',
        'border-radius:16px',
        'background:rgba(0,120,255,0.2)',
        'align-items:center',
        'justify-content:center',
    ].join(';');
    document.body.appendChild(overlay);
    console.log('[Tmpspace] overlay created, body=', document.body);

    var dragCounter = 0;

    function hasFiles(e) {
        console.log('[Tmpspace] hasFiles check, types=', e.dataTransfer.types);
        for (var i = 0; i < e.dataTransfer.types.length; i++) {
            if (e.dataTransfer.types[i] === 'Files') return true;
        }
        return false;
    }

    function showOverlay() {
        console.log('[Tmpspace] showOverlay');
        overlay.style.display = 'flex';
        window.webkit.messageHandlers.bridge.postMessage(({
            moduleName:'core',
            methodName:'notifyDragEntered',
            parameters:'{}'
        }));
    }

    function hideOverlay() {
        console.log('[Tmpspace] hideOverlay');
        overlay.style.display = 'none';
        window.webkit.messageHandlers.bridge.postMessage(({
            moduleName:'core',
            methodName:'notifyDragLeft',
            parameters:'{}'
        }));
    }

    document.addEventListener('dragenter', function(e) {
        console.log('[Tmpspace] dragenter', e.dataTransfer.types);
        if (!hasFiles(e)) { console.log('[Tmpspace] dragenter - no files'); return; }
        dragCounter++;
        console.log('[Tmpspace] dragenter counter=', dragCounter);
        if (dragCounter === 1) showOverlay();
    }, true);

    document.addEventListener('dragleave', function(e) {
        console.log('[Tmpspace] dragleave');
        if (!hasFiles(e)) return;
        dragCounter--;
        console.log('[Tmpspace] dragleave counter=', dragCounter);
        if (dragCounter <= 0) { dragCounter = 0; hideOverlay(); }
    }, true);

    document.addEventListener('dragover', function(e) {
        console.log('[Tmpspace] dragover');
        if (!hasFiles(e)) return;
        e.preventDefault();
        e.stopPropagation();
    }, true);

    document.addEventListener('drop', function(e) {
        console.log('[Tmpspace] drop event!');
        if (!hasFiles(e)) { console.log('[Tmpspace] drop - no files'); return; }
        e.preventDefault();
        e.stopPropagation();
        dragCounter = 0;
        hideOverlay();

        var files = e.dataTransfer.files;
        console.log('[Tmpspace] drop files count=', files.length);
        var results = [];
        var total = files.length;

        function readNext(idx) {
            if (idx >= total) {
                console.log('[Tmpspace] all files read, posting to bridge');
                window.webkit.messageHandlers.bridge.postMessage(({
                    moduleName:'core',
                    methodName:'notifyFilesDropped',
                    parameters:JSON.stringify(results)
                }));
                return;
            }
            var file = files[idx];
            console.log('[Tmpspace] reading file', idx, file.name, file.size);
            var reader = new FileReader();
            reader.onload = function(ev) {
                results.push({
                    name: file.name,
                    type: file.type,
                    size: file.size,
                    data: ev.target.result
                });
                readNext(idx + 1);
            };
            reader.onerror = function() {
                console.log('[Tmpspace] read error for', file.name);
                results.push({ name:file.name, type:file.type, size:file.size, data:null });
                readNext(idx + 1);
            };
            reader.readAsDataURL(file);
        }
        readNext(0);
    }, true);

    console.log('[Tmpspace] drag handler installed successfully');
    // Confirm to Swift that injection succeeded.
    window.webkit.messageHandlers.bridge.postMessage(({
        moduleName:'core',
        methodName:'notifyDragHandlerInstalled',
        parameters:'{}'
    }));
})();
"""
        webView?.evaluateJavaScript(script)
    }
}

// MARK: - File Drop Item

/// A file dropped onto the editor, with its base64-encoded data URL.
public struct FileDropItem: Decodable, Sendable {
    public let name: String
    public let type: String
    public let size: Int
    /// Data URL (e.g. `data:image/png;base64,...`) or `nil` if the read failed.
    public let data: String?
}

// MARK: - Helpers

/// Returns a JSON-encoded string suitable for embedding in a JavaScript expression.
private func encodeJSON(_ string: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed),
          let json = String(data: data, encoding: .utf8) else {
        // If we can't JSON-encode the string, fall back to a sanitised version:
        // strip control characters and backslash-escape quotes / backslashes.
        let sanitised = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(sanitised)\""
    }
    return json
}
