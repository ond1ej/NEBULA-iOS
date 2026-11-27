import SwiftUI

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

/// NEBULA's own visual identity: calm neutral surfaces, one restrained violet accent, native materials.
/// Every color adapts to light / dark mode and to Increase Contrast.
public enum NColor {
    /// Restrained violet accent (buttons, links, the user's bubble, selection).
    public static let accent = dynamic(light: 0x6D4AFF, dark: 0x9B87FF, lightHC: 0x5230E0, darkHC: 0xB7A8FF)
    /// Second stop of the accent gradient (subtle shift towards indigo).
    public static let accentDeep = dynamic(light: 0x4F46E5, dark: 0x7C6CF2)
    public static let accentSoft = dynamic(light: 0xEEEAFF, dark: 0x2A2447)
    public static let onAccent = Color.white

    public static let background = dynamic(light: 0xF7F7FA, dark: 0x0B0B10)
    public static let surface = dynamic(light: 0xFFFFFF, dark: 0x16161E)
    public static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x1E1E28)
    public static let surfaceSunken = dynamic(light: 0xEFEFF4, dark: 0x101016)
    public static let separator = dynamic(light: 0xE3E3EA, dark: 0x2A2A36)

    public static let textPrimary = dynamic(light: 0x111118, dark: 0xF3F3F7)
    public static let textSecondary = dynamic(light: 0x5D5D6B, dark: 0xA6A6B5)
    public static let textTertiary = dynamic(light: 0x8E8E9C, dark: 0x6E6E7E)

    public static let success = dynamic(light: 0x16A34A, dark: 0x4ADE80)
    public static let warning = dynamic(light: 0xD97706, dark: 0xFBBF24)
    public static let danger = dynamic(light: 0xDC2626, dark: 0xF87171)
    public static let info = dynamic(light: 0x2563EB, dark: 0x60A5FA)

    public static let bubbleAssistant = dynamic(light: 0xFFFFFF, dark: 0x1B1B24)
    public static let codeBackground = dynamic(light: 0xF3F2F8, dark: 0x111118)

    public static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { t in
            let hc = t.accessibilityContrast == .high
            let hex = t.userInterfaceStyle == .dark ? (hc ? (darkHC ?? dark) : dark) : (hc ? (lightHC ?? light) : light)
            return UIColor(hex: hex)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                                                     .accessibilityHighContrastVibrantDark]) != nil
            let hc = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                                 .accessibilityHighContrastVibrantLight,
                                                 .accessibilityHighContrastVibrantDark]) != nil
            let hex = isDark ? (hc ? (darkHC ?? dark) : dark) : (hc ? (lightHC ?? light) : light)
            return NSColor(hex: hex)
        })
        #endif
    }
}

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Spacing scale (points).
public enum NSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum NRadius {
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 18
    public static let bubble: CGFloat = 20
    public static let xl: CGFloat = 28
}

/// Typography on top of the system font so Dynamic Type works everywhere.
public enum NFont {
    public static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    public static let title = Font.system(.title2, design: .rounded, weight: .semibold)
    public static let headline = Font.system(.headline, design: .default, weight: .semibold)
    public static let body = Font.body
    public static let callout = Font.callout
    public static let caption = Font.caption
    public static let footnote = Font.footnote
    public static let mono = Font.system(.callout, design: .monospaced)
    public static let monoSmall = Font.system(.footnote, design: .monospaced)
}
