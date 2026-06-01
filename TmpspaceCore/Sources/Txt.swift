import SwiftUI

/// Localisation helpers. All user-visible strings should go through these
/// so the app can switch between Chinese and English based on system locale.
public enum Txt {

    /// In Xcode .app archives the main bundle contains all resources;
    /// in SPM dev builds each module has its own resource bundle.
    /// We probe Bundle.main first; the module bundle is loaded via Bundle(path:)
    /// so we get nil instead of a crash when it doesn't exist.
    private static let bundle: Bundle = {
        if Bundle.main.url(forResource: "Localizable", withExtension: "xcstrings") != nil {
            return Bundle.main
        }
        if let moduleBundle = Bundle(path: Bundle.main.bundleURL.appendingPathComponent("TmpspaceCore_TmpspaceCore.bundle").path) {
            return moduleBundle
        }
        return Bundle.main
    }()

    /// Returns a localised `String`.
    ///
    /// Usage:
    /// ```swift
    /// Txt.str("显示/隐藏")          // static
    /// Txt.str("编辑面板 \(idx)")     // interpolated
    /// ```
    public static func str(
        _ key: String.LocalizationValue,
        table: String? = nil,
        comment: StaticString? = nil
    ) -> String {
        String(localized: key, table: table, bundle: bundle, comment: comment)
    }

    /// Returns a localised SwiftUI `Text`.
    ///
    /// Usage:
    /// ```swift
    /// Txt.text("编辑器")
    /// ```
    public static func text(
        _ key: String.LocalizationValue,
        table: String? = nil,
        comment: StaticString? = nil
    ) -> Text {
        Text(verbatim: String(localized: key, table: table, bundle: bundle, comment: comment))
    }
}
