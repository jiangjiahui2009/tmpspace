//
//  FormatToolbarView.swift
//  TmpspaceEditor
//
//  A compact horizontal toolbar containing Markdown formatting buttons.
//  Designed to be embedded in the ~32pt floating panel toolbar.
//

import AppKit
import TmpspaceCore

/// A horizontal button strip that sends `EditorCommand` values to an editor provider.
///
/// Usage:
/// ```swift
/// let toolbar = FormatToolbarView(editorProvider: viewController, panelId: id)
/// toolbar.frame.size.height = 32
/// panel.titleBarView.addSubview(toolbar)
/// ```
public final class FormatToolbarView: NSView {

    // MARK: - Properties

    private weak var editorProvider: (any EditorProviderProtocol)?
    private let panelId: UUID

    private lazy var stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .equalSpacing
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - Init

    /// - Parameters:
    ///   - editorProvider: The object that handles command execution (usually an `EditorViewController`).
    ///   - panelId: The panel this toolbar controls.
    public init(editorProvider: any EditorProviderProtocol, panelId: UUID) {
        self.editorProvider = editorProvider
        self.panelId = panelId
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func setUp() {
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Add the format buttons.
        let buttons: [(title: String, command: EditorCommand, toolTip: String)] = [
            ("无序列表", .unorderedList, "Toggle bullet list"),
            ("有序列表", .orderedList, "Toggle numbered list"),
            ("待办事项", .taskList, "Toggle task list"),
        ]

        for item in buttons {
            let button = makeButton(title: item.title, command: item.command, toolTip: item.toolTip)
            stackView.addArrangedSubview(button)
        }
    }

    // MARK: - Button Factory

    private func makeButton(title: String, command: EditorCommand, toolTip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(buttonClicked(_:)))

        // Store the command in the button's tag via a mapping table.
        associate(command: command, with: button)

        button.bezelStyle = .accessoryBarAction
        button.toolTip = toolTip
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        return button
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let command = command(for: sender) else { return }
        editorProvider?.executeCommand(for: panelId, command: command)
    }

    // MARK: - Command Association

    /// Uses `objc_setAssociatedObject` to attach an `EditorCommand` value to an `NSButton`.
    private func associate(command: EditorCommand, with button: NSButton) {
        objc_setAssociatedObject(button, &FormatToolbarView.commandKey, CommandWrapper(command), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func command(for button: NSButton) -> EditorCommand? {
        guard let wrapper = objc_getAssociatedObject(button, &FormatToolbarView.commandKey) as? CommandWrapper else {
            return nil
        }
        return wrapper.command
    }

    private static var commandKey: UInt8 = 0
}

/// Simple box to wrap an `EditorCommand` for use with `objc_setAssociatedObject`.
private final class CommandWrapper: NSObject {
    let command: EditorCommand
    init(_ command: EditorCommand) {
        self.command = command
    }
}
