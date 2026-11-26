import SwiftUI
import UIKit
import CoreText

// MARK: - Colour tokens (Figma: 01 — Design System)

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum NX {
    // Brand
    static let royal = Color(hex: 0x1E3FA8)
    static let navy = Color(hex: 0x0A1633)
    static let steel = Color(hex: 0x8A93A0)
    static let ice = Color(hex: 0x6FA8FF)
    static let cream = Color(hex: 0xF6F3EE)

    // Surfaces
    static let base = Color(hex: 0x08090D)
    static let raised = Color.white.opacity(0.045)
    static let overlay = Color.white.opacity(0.075)
    static let field = Color(hex: 0x05060A)

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xA7B0BE)
    static let textMuted = Color(hex: 0x8A93A0)
    static let textOnLight = navy

    // Borders
    static let borderSubtle = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.16)
    static let borderFocus = ice

    // Status
    static let success = Color(hex: 0x3DD6A0)
    static let warning = Color(hex: 0xF5B544)
    static let error = Color(hex: 0xFF6B7A)
    static let info = ice

    // Spacing (8 pt grid) and radii
    enum S { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 24, x3: CGFloat = 32, x4: CGFloat = 40 }
    enum R { static let sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24 }
    static let margin: CGFloat = 20
}

// MARK: - Typography (Sora)

enum FontLoader {
    /// Registers bundled Sora files if present. Without them the app falls back to the
    /// system font at the same sizes and weights.
    static func registerBundledFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        hasSora = UIFont(name: "Sora-Regular", size: 12) != nil
    }
    static var hasSora = false
}

extension Font {
    static func sora(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if FontLoader.hasSora {
            let name: String
            switch weight {
            case .bold, .heavy, .black: name = "Sora-Bold"
            case .semibold: name = "Sora-SemiBold"
            case .medium: name = "Sora-Medium"
            case .light, .thin, .ultraLight: name = "Sora-Light"
            default: name = "Sora-Regular"
            }
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }

    // Type scale from the design system
    static let nxDisplay = sora(36, .bold)
    static let nxH1 = sora(28, .bold)
    static let nxH2 = sora(22, .bold)
    static let nxH3 = sora(18, .semibold)
    static let nxBodyL = sora(17)
    static let nxBody = sora(15)
    static let nxBodyS = sora(13)
    static let nxLabel = sora(13, .semibold)
    static let nxCaption = sora(12)
    static let nxOverline = sora(11, .semibold)
    static let nxNumberXL = sora(56, .light)
    static let nxNumberL = sora(32, .regular)
}

struct Overline: View {
    let text: String
    var color: Color = NX.ice
    init(_ text: String, color: Color = NX.ice) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(.nxOverline)
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

// MARK: - Background

/// Near-black canvas with the soft navy glow at the top seen on every screen.
struct NXBackground: View {
    var glow: Double = 1
    var body: some View {
        ZStack {
            NX.base
            RadialGradient(colors: [NX.royal.opacity(0.28 * glow), NX.navy.opacity(0.35 * glow), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func nxScreen(glow: Double = 1) -> some View {
        background(NXBackground(glow: glow))
            .toolbar(.hidden, for: .navigationBar)
    }

    func nxCard(padding: CGFloat = NX.S.l, radius: CGFloat = NX.R.xl) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.03)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(NX.borderSubtle, lineWidth: 1))
    }
}
