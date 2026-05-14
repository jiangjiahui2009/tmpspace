import AppKit

/// Predefined color themes for floating panels.
public enum PanelColorTheme: String, CaseIterable, Codable, Sendable {
    case system      // Follows system appearance
    case light       // Always light
    case dark        // Always dark
    case warmYellow  // Warm yellow (like sticky notes)
    case coolBlue    // Cool blue
    case softGreen   // Soft green
    case lavender    // Lavender purple

    public var displayName: String {
        switch self {
        case .system:     return "跟随系统"
        case .light:      return "浅色"
        case .dark:       return "深色"
        case .warmYellow: return "暖黄"
        case .coolBlue:   return "冷蓝"
        case .softGreen:  return "柔绿"
        case .lavender:   return "淡紫"
        }
    }

    /// Background color for the panel chrome (toolbar area).
    public var chromeColor: NSColor {
        switch self {
        case .system:     return NSColor.windowBackgroundColor
        case .light:      return NSColor(white: 0.97, alpha: 1)
        case .dark:       return NSColor(white: 0.15, alpha: 1)
        case .warmYellow: return NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.85, alpha: 1)
        case .coolBlue:   return NSColor(calibratedRed: 0.88, green: 0.94, blue: 1.0, alpha: 1)
        case .softGreen:  return NSColor(calibratedRed: 0.88, green: 1.0, blue: 0.90, alpha: 1)
        case .lavender:   return NSColor(calibratedRed: 0.94, green: 0.90, blue: 1.0, alpha: 1)
        }
    }

    /// Effective appearance for the panel content area.
    public var effectiveAppearance: NSAppearance? {
        switch self {
        case .system:     return nil
        case .light:      return NSAppearance(named: .aqua)
        case .dark:       return NSAppearance(named: .darkAqua)
        case .warmYellow, .coolBlue, .softGreen, .lavender:
            return NSAppearance(named: .aqua)
        }
    }
}
