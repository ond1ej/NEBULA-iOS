import SwiftUI
import NEBULADesignSystem

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Colors used by the Markdown renderer and the syntax highlighter. Every color is dynamic: it resolves for
/// light / dark mode (and Increase Contrast) at draw time, so cached attributed strings stay correct when the
/// appearance changes. The highlight colors follow Xcode's default themes, tuned for NEBULA's code background.
enum MarkdownPalette {
    /// Background behind `inline code`.
    static let inlineCodeBackground = dynamic(light: 0xE9E7F2, dark: 0x2C2B39, lightHC: 0xDCD9EA, darkHC: 0x3A3950)
    /// Header strip of code blocks and tables.
    static let headerBackground = dynamic(light: 0xEAE8F2, dark: 0x1A1A24)

    static let keyword = dynamic(light: 0x9B2393, dark: 0xFC5FA3, lightHC: 0x7A1A73, darkHC: 0xFF85BA)
    static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D, lightHC: 0x9E1310, darkHC: 0xFF8A80)
    static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69, lightHC: 0x1400A0, darkHC: 0xE5D78A)
    static let comment = dynamic(light: 0x6C7986, dark: 0x7F8C98, lightHC: 0x4C5866, darkHC: 0xA3AFBA)
    static let type = dynamic(light: 0x0B4F79, dark: 0x5DD8FF, lightHC: 0x073A5A, darkHC: 0x8AE4FF)
    static let function = dynamic(light: 0x326D74, dark: 0x67B7A4, lightHC: 0x22525A, darkHC: 0x8BD3C2)
    static let property = dynamic(light: 0x6F42C1, dark: 0xB392F0, lightHC: 0x5530A0, darkHC: 0xCBB2FF)
    static let tag = dynamic(light: 0x116329, dark: 0x7EE787, lightHC: 0x0A4A1E, darkHC: 0xA5F3AC)
    static let attribute = dynamic(light: 0x953800, dark: 0xFFA657, lightHC: 0x732B00, darkHC: 0xFFC08A)
    static let variable = dynamic(light: 0x0550AE, dark: 0x79C0FF, lightHC: 0x033D87, darkHC: 0xA5D6FF)
    static let meta = dynamic(light: 0x643820, dark: 0xFD8F3F, lightHC: 0x4A2814, darkHC: 0xFFAD70)
    static let inserted = dynamic(light: 0x116329, dark: 0x56D364, lightHC: 0x0A4A1E, darkHC: 0x8AE89A)
    static let deleted = dynamic(light: 0x82071E, dark: 0xFF7B72, lightHC: 0x5E0515, darkHC: 0xFFA198)
    static let insertedBackground = dynamic(light: 0xDAFBE1, dark: 0x12301D, alpha: 0.9)
    static let deletedBackground = dynamic(light: 0xFFEBE9, dark: 0x3A1518, alpha: 0.9)

    static func color(for kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .number: number
        case .comment: comment
        case .type: type
        case .function: function
        case .property: property
        case .tag: tag
        case .attribute: attribute
        case .variable: variable
        case .meta: meta
        case .inserted: inserted
        case .deleted: deleted
        }
    }

    static func background(for kind: SyntaxTokenKind) -> Color? {
        switch kind {
        case .inserted: insertedBackground
        case .deleted: deletedBackground
        default: nil
        }
    }

    /// Same construction as the design system's colors (light / dark / high-contrast variants).
    static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil,
                        alpha: CGFloat = 1) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let highContrast = traits.accessibilityContrast == .high
            let hex = traits.userInterfaceStyle == .dark ? (highContrast ? (darkHC ?? dark) : dark)
                                                         : (highContrast ? (lightHC ?? light) : light)
            return UIColor(markdownHex: hex, alpha: alpha)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                                     .accessibilityHighContrastVibrantDark]) != nil
            let highContrast = appearance.bestMatch(from: [.accessibilityHighContrastAqua,
                                                           .accessibilityHighContrastDarkAqua,
                                                           .accessibilityHighContrastVibrantLight,
                                                           .accessibilityHighContrastVibrantDark]) != nil
            let hex = isDark ? (highContrast ? (darkHC ?? dark) : dark) : (highContrast ? (lightHC ?? light) : light)
            return NSColor(markdownHex: hex, alpha: alpha)
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(markdownHex hex: UInt32, alpha: CGFloat) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(markdownHex hex: UInt32, alpha: CGFloat) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif
