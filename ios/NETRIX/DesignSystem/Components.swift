import SwiftUI

// MARK: - Chips

struct StatusChip: View {
    let status: GameStatus
    var color: Color {
        switch status {
        case .pending: return NX.warning
        case .inReview: return NX.info
        case .completed: return NX.success
        case .needsAction: return NX.error
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.rawValue).font(.sora(12, .medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Delta chip, e.g. "▲ 1.7 vs season".
struct DeltaChip: View {
    let text: String
    var positive: Bool? = true
    var body: some View {
        let color: Color = positive == nil ? NX.textSecondary : (positive! ? NX.success : NX.error)
        HStack(spacing: 4) {
            if let positive { Image(systemName: positive ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8)) }
            Text(text).font(.sora(12, .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Selectable chip (age group, focus areas, filters).
struct ChoiceChip: View {
    let title: String
    let selected: Bool
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        Button { Haptics.select(); action() } label: {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                else if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(NX.ice) }
                Text(title).font(.sora(14, .medium))
            }
            .foregroundStyle(selected ? NX.navy : .white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(Capsule().fill(selected ? NX.cream : Color.white.opacity(0.06)))
            .overlay(Capsule().stroke(selected ? .clear : NX.borderSubtle))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// Week / Month / Season pill switcher.
struct PillSegment<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    var height: CGFloat = 40
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { opt in
                Button {
                    if selection != opt { Haptics.select() }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = opt }
                } label: {
                    Text(title(opt))
                        .font(.sora(14, .medium))
                        .foregroundStyle(selection == opt ? NX.navy : NX.textSecondary)
                        .frame(maxWidth: .infinity).frame(height: height - 8)
                        .background {
                            if selection == opt { Capsule().fill(NX.cream).matchedGeometryEffect(id: "pill", in: ns) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(NX.borderSubtle))
    }
}

// MARK: - Bars

struct AppBar<Trailing: View>: View {
    let title: String
    var onBack: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        ZStack {
            Text(title).font(.sora(17, .semibold)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 56)
            HStack {
                if let onBack { CircleIconButton(systemName: "arrow.left", action: onBack).accessibilityLabel("Back") }
                Spacer()
                trailing()
            }
        }
        .frame(height: 56)
        .padding(.horizontal, NX.margin)
    }
}

extension AppBar where Trailing == EmptyView {
    init(title: String, onBack: (() -> Void)?) { self.init(title: title, onBack: onBack, trailing: { EmptyView() }) }
}

struct StepBars: View {
    let total: Int
    let current: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Capsule().fill(i < current ? Color.white : Color.white.opacity(0.14)).frame(height: 3)
            }
        }
        .animation(.easeInOut, value: current)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}

/// Labelled progress bar row ("Positioning 82").
struct MeterRow: View {
    let title: String
    let valueText: String
    let fraction: Double
    var color: Color = NX.ice
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.nxBody).foregroundStyle(.white)
                Spacer()
                Text(valueText).font(.sora(14, .semibold)).foregroundStyle(.white).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NX.royal.opacity(0.35))
                    Capsule().fill(color).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rings

/// Ring with the value in the middle (report overview, game summary).
struct ScoreRing: View {
    let fraction: Double
    let value: String
    let caption: String
    var size: CGFloat = 132
    var lineWidth: CGFloat = 12
    @State private var shown: Double

    init(fraction: Double, value: String, caption: String, size: CGFloat = 132, lineWidth: CGFloat = 12, animated: Bool = true) {
        self.fraction = fraction; self.value = value; self.caption = caption; self.size = size; self.lineWidth = lineWidth
        _shown = State(initialValue: animated ? 0 : min(max(fraction, 0), 1))
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(NX.ice, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: NX.ice.opacity(0.35), radius: 8)
            VStack(spacing: 2) {
                Text(value).font(.sora(size * 0.3, .light)).foregroundStyle(.white).monospacedDigit().minimumScaleFactor(0.6)
                Text(caption.uppercased()).font(.sora(10, .semibold)).tracking(1.2).foregroundStyle(NX.textMuted)
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { shown = min(max(fraction, 0), 1) } }
        .onChange(of: fraction) { _, f in withAnimation(.easeOut(duration: 0.6)) { shown = min(max(f, 0), 1) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(value)")
    }
}

/// Segmented tick dial used on the home hero.
struct TickDial: View {
    let fraction: Double
    var ticks = 48
    @State private var shown: Double = 0
    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                ForEach(0..<ticks, id: \.self) { i in
                    let t = Double(i) / Double(ticks)
                    let lit = t < shown
                    Capsule()
                        .fill(lit ? NX.ice.opacity(0.55 + 0.45 * t) : Color.white.opacity(0.14))
                        .frame(width: 3, height: lit && abs(t - shown) < 1.5 / Double(ticks) ? 18 : 12)
                        .offset(y: -r + 9)
                        .rotationEffect(.degrees(t * 300 - 150))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1)) { shown = min(max(fraction, 0), 1) } }
        .onChange(of: fraction) { _, f in withAnimation(.easeOut(duration: 0.6)) { shown = min(max(f, 0), 1) } }
        .accessibilityHidden(true)
    }
}

// MARK: - States

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var tint: Color = NX.ice
    var body: some View {
        VStack(spacing: NX.S.m) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Circle().fill(tint.opacity(0.14)))
            Text(title).font(.nxH3).foregroundStyle(.white)
            Text(message).font(.nxBodyS).foregroundStyle(NX.textSecondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.nxPrimary).padding(.top, NX.S.s)
            }
        }
        .padding(NX.S.xxl)
        .frame(maxWidth: .infinity)
        .nxCard(padding: 0)
    }
}

struct ErrorStateCard: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        EmptyStateCard(icon: "exclamationmark.circle", title: "Something went wrong",
                       message: message, actionTitle: "Try again", action: retry, tint: NX.error)
    }
}

struct SkeletonBlock: View {
    var height: CGFloat = 16
    var width: CGFloat? = nil
    @State private var phase = false
    var body: some View {
        RoundedRectangle(cornerRadius: NX.R.md, style: .continuous)
            .fill(Color.white.opacity(phase ? 0.09 : 0.05))
            .frame(width: width, height: height)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { phase = true } }
    }
}

struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(height: 10, width: 80)
            SkeletonBlock(height: 18, width: 160)
            SkeletonBlock(height: 8)
            SkeletonBlock(height: 8, width: 200)
            SkeletonBlock(height: 52)
        }
        .nxCard()
        .accessibilityLabel("Loading")
    }
}

// MARK: - Banner / toast

struct BannerView: View {
    let toast: Toast
    var color: Color {
        switch toast.style { case .success: NX.success; case .error: NX.error; case .info: NX.info }
    }
    var icon: String {
        switch toast.style { case .success: "checkmark"; case .error: "exclamationmark.circle"; case .info: "info.circle" }
    }
    var body: some View {
        HStack(alignment: .top, spacing: NX.S.m) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.nxLabel).foregroundStyle(.white)
                if let m = toast.message { Text(m).font(.nxCaption).foregroundStyle(NX.textSecondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(NX.S.l)
        .background(RoundedRectangle(cornerRadius: NX.R.lg, style: .continuous).fill(Color(hex: 0x15171D)))
        .overlay(RoundedRectangle(cornerRadius: NX.R.lg, style: .continuous).stroke(NX.borderSubtle))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}

// MARK: - Data bits

/// Small stat tile: "SAVE % 91.2" with a delta line.
struct StatTile<Footer: View>: View {
    let title: String
    let value: String
    var unit: String? = nil
    @ViewBuilder var footer: () -> Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.nxOverline).tracking(1.2).foregroundStyle(NX.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.sora(30, .light)).foregroundStyle(.white).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                if let unit { Text(unit).font(.nxBodyS).foregroundStyle(NX.textMuted) }
            }
            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nxCard(radius: 20)
        .accessibilityElement(children: .combine)
    }
}

extension StatTile where Footer == EmptyView {
    init(title: String, value: String, unit: String? = nil) {
        self.init(title: title, value: value, unit: unit, footer: { EmptyView() })
    }
}

/// Glowing sparkline drawn from a series of values.
struct Sparkline: View {
    let values: [Double]
    var color: Color = .white
    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: color.opacity(0.6), radius: 4)
                if let last = pts.last {
                    Circle().fill(color).frame(width: 9, height: 9).position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }
    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return [] }
        let span = max(hi - lo, 0.0001)
        return values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: size.height - 4 - (size.height - 8) * CGFloat((v - lo) / span))
        }
    }
}

/// Film thumbnail placeholder: rink-tinted square with a play glyph.
struct FilmThumb: View {
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x8C9FD9), Color(hex: 0x4D63A8)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "play.fill").font(.system(size: size * 0.28)).foregroundStyle(.white.opacity(0.9)))
            .frame(width: size, height: size)
    }
}

struct GameRow: View {
    let entry: GameEntry
    var subtitle: String
    var body: some View {
        HStack(spacing: NX.S.m) {
            FilmThumb()
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.sora(15, .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(subtitle).font(.nxCaption).foregroundStyle(NX.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusChip(status: entry.status)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(NX.textMuted)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Section header with optional trailing action ("Recent analysis   See all ›").
struct SectionHeader: View {
    let title: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    var body: some View {
        HStack {
            Text(title).font(.nxH3).foregroundStyle(.white)
            Spacer()
            if let action, let onAction {
                Button(action: onAction) {
                    HStack(spacing: 4) { Text(action); Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
                        .font(.nxLabel).foregroundStyle(NX.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Settings-style row with leading icon.
struct ListRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = .white
    var body: some View {
        HStack(spacing: NX.S.m) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(tint == .white ? NX.textSecondary : tint)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.nxBody).foregroundStyle(tint)
                if let subtitle { Text(subtitle).font(.nxCaption).foregroundStyle(NX.textMuted) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(NX.textMuted)
        }
        .padding(.horizontal, NX.S.l).frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: NX.R.lg, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: NX.R.lg, style: .continuous).stroke(NX.borderSubtle))
        .contentShape(Rectangle())
    }
}

/// Animated concentric rings around an icon (check your inbox, game submitted).
struct HaloIcon: View {
    let systemName: String
    var badge = true
    var tint: Color = NX.ice
    @State private var pulse = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle().stroke(Color.white.opacity(0.06 - Double(i) * 0.015), lineWidth: 1)
                    .frame(width: 120 + CGFloat(i) * 56, height: 120 + CGFloat(i) * 56)
                    .scaleEffect(pulse ? 1.03 : 0.97)
            }
            Circle().fill(RadialGradient(colors: [NX.royal.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 120))
                .frame(width: 240, height: 240)
            Circle().fill(Color.white.opacity(0.07)).frame(width: 88, height: 88)
                .overlay(Circle().stroke(NX.borderStrong))
            Image(systemName: systemName).font(.system(size: 26, weight: .medium)).foregroundStyle(tint)
            if badge {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(NX.navy)
                    .frame(width: 24, height: 24).background(Circle().fill(NX.success))
                    .offset(x: 34, y: -34)
            }
        }
        .frame(height: 240)
        .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever()) { pulse = true } }
        .accessibilityHidden(true)
    }
}
