import Foundation

/// Data model representing a single floating editor panel.
public struct PanelModel: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier for this panel.
    public let id: UUID
    public var content: String
    public var title: String
    public var positionX: CGFloat
    public var positionY: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var isVisible: Bool
    public var alwaysOnTop: Bool
    public var createdAt: Date
    public var lastModifiedAt: Date

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        content: String = "",
        title: String = "未命名",
        positionX: CGFloat = -1,
        positionY: CGFloat = -1,
        width: CGFloat = Constants.defaultPanelWidth,
        height: CGFloat = Constants.defaultPanelHeight,
        isVisible: Bool = false,
        alwaysOnTop: Bool = true,
        createdAt: Date = Date(),
        lastModifiedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.title = title
        self.positionX = positionX
        self.positionY = positionY
        self.width = width
        self.height = height
        self.isVisible = isVisible
        self.alwaysOnTop = alwaysOnTop
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
    }

    /// Returns the panel's position as a CGPoint, or nil if not yet positioned.
    public var position: CGPoint? {
        guard positionX >= 0, positionY >= 0 else { return nil }
        return CGPoint(x: positionX, y: positionY)
    }

    public var size: CGSize {
        CGSize(width: width, height: height)
    }
}
