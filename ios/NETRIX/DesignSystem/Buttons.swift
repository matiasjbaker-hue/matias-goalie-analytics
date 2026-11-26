import SwiftUI

/// Pill buttons from the design system: primary (cream), secondary (dark), tertiary (ice text), destructive.
struct NXButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, tertiary, destructive }
    var kind: Kind = .primary
    var isLoading = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return ZStack {
            configuration.label.opacity(isLoading ? 0 : 1)
            if isLoading { ProgressView().tint(foreground) }
        }
        .font(.sora(16, .medium))
        .foregroundStyle(foreground)
        .frame(maxWidth: kind == .tertiary ? nil : .infinity)
        .frame(height: kind == .tertiary ? 36 : 56)
        .padding(.horizontal, kind == .tertiary ? 4 : NX.S.xl)
        .background(background)
        .overlay(border)
        .clipShape(Capsule())
        .scaleEffect(pressed ? 0.98 : 1)
        .opacity(pressed ? 0.88 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .contentShape(Capsule())
    }

    private var foreground: Color {
        guard isEnabled else { return kind == .primary ? Color.white.opacity(0.45) : NX.textMuted }
        switch kind {
        case .primary: return NX.textOnLight
        case .secondary: return .white
        case .tertiary: return NX.ice
        case .destructive: return NX.error
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary:
            if isEnabled { NX.cream } else { Color.white.opacity(0.14) }
        case .secondary:
            LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
        case .tertiary:
            Color.clear
        case .destructive:
            NX.error.opacity(0.12)
        }
    }

    @ViewBuilder private var border: some View {
        switch kind {
        case .secondary: Capsule().stroke(NX.borderSubtle, lineWidth: 1)
        case .destructive: Capsule().stroke(NX.error.opacity(0.35), lineWidth: 1)
        default: EmptyView()
        }
    }
}

extension ButtonStyle where Self == NXButtonStyle {
    static var nxPrimary: NXButtonStyle { NXButtonStyle(kind: .primary) }
    static var nxSecondary: NXButtonStyle { NXButtonStyle(kind: .secondary) }
    static var nxTertiary: NXButtonStyle { NXButtonStyle(kind: .tertiary) }
    static var nxDestructive: NXButtonStyle { NXButtonStyle(kind: .destructive) }
    static func nxPrimary(loading: Bool) -> NXButtonStyle { NXButtonStyle(kind: .primary, isLoading: loading) }
    static func nxSecondary(loading: Bool) -> NXButtonStyle { NXButtonStyle(kind: .secondary, isLoading: loading) }
    static func nxDestructive(loading: Bool) -> NXButtonStyle { NXButtonStyle(kind: .destructive, isLoading: loading) }
}

/// Round 40pt icon button used for back and notifications in the app bar.
struct CircleIconButton: View {
    let systemName: String
    var badge = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().stroke(NX.borderSubtle, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(NX.ice).frame(width: 8, height: 8).offset(x: -8, y: 8) }
                }
        }
        .buttonStyle(.plain)
    }
}

/// "Already have an account? Log in" style footer line.
struct InlinePrompt: View {
    let text: String
    let action: String
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            (Text(text + " ").foregroundColor(NX.textSecondary) + Text(action).foregroundColor(NX.ice).fontWeight(.semibold))
                .font(.nxBody)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
    }
}
