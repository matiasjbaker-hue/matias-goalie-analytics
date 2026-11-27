import SwiftUI

/// The NETRIX mark (Figma: Logo & Branding Asset, "Concept 05 — Athlos"): the stride,
/// the letter and the stick. Traced from the construction drawing; aspect ≈ 2.15 : 1.
struct NetrixMark: Shape {
    static let aspect: CGFloat = 1286.0 / 598.0

    // Points in the construction drawing's units (box 1286 × 598).
    private static let body: [CGPoint] = ([
        (69, 598), (0, 540), (456, 0), (757, 0), (829, 82), (901, 0), (1249, 0),
        (924, 381), (893, 345), (762, 345), (859, 459), (743, 598), (511, 598),
        (442, 540), (656, 288), (608, 233), (296, 598),
    ] as [(CGFloat, CGFloat)]).map { CGPoint(x: $0.0, y: $0.1) }

    private static let stick: [CGPoint] = ([
        (833, 378), (877, 378), (932, 441), (1286, 441), (1286, 598), (1018, 598),
    ] as [(CGFloat, CGFloat)]).map { CGPoint(x: $0.0, y: $0.1) }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 1286, rect.height / 598)
        let w = 1286 * scale, h = 598 * scale
        let origin = CGPoint(x: rect.midX - w / 2, y: rect.midY - h / 2)
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
        var path = Path()
        path.addLines(Self.body.map(map)); path.closeSubpath()
        path.addLines(Self.stick.map(map)); path.closeSubpath()
        return path
    }
}

/// Mark + wordmark lockup used on the splash and welcome screens.
struct NetrixLockup: View {
    var height: CGFloat = 22
    var color: Color = .white
    var body: some View {
        HStack(spacing: height * 0.45) {
            NetrixMark()
                .fill(color)
                .frame(width: height * NetrixMark.aspect, height: height)
            Text("NETRIX")
                .font(.sora(height * 0.95, .bold))
                .tracking(height * 0.03)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("NETRIX")
    }
}

#Preview {
    VStack(spacing: 40) {
        NetrixMark().fill(.white).frame(width: 215, height: 100)
        NetrixLockup()
    }
    .padding()
    .background(NX.base)
}
