import SwiftUI

/// The Nocturne design tokens from the design file, translated to SwiftUI.
/// Dark, low-chroma surface with a soft purple accent. Kept in one place so the
/// picker reads as a faithful implementation of the design rather than an
/// approximation of it.
enum Theme {
    // Core surfaces
    static let bg = Color(hex: 0x161826)
    static let surface = Color(hex: 0x232532)
    static let text = Color(hex: 0xE9E9ED)
    static let divider = Color.white.opacity(0.16)

    // Neutrals
    static let neutral400 = Color(hex: 0xB2B6CA)
    static let neutral500 = Color(hex: 0x9397AB)
    static let neutral600 = Color(hex: 0x75798C)

    // Accent (purple)
    static let accent = Color(hex: 0x9184D9)
    static let accent200 = Color(hex: 0xE7E5FE)
    static let accent300 = Color(hex: 0xD2CEFD)
    static let accent700 = Color(hex: 0x5D5294)
    static let accent900 = Color(hex: 0x2B2741)

    // Row selection
    static let rowSelectedBG = accent900
    static let rowSelectedStroke = accent700

    // Radii
    static let radiusPanel: CGFloat = 14
    static let radiusRow: CGFloat = 8
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
