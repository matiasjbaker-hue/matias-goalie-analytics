import SwiftUI

/// Step-by-step setup guide shown before the first recording (and from the recorder's "?").
struct RecordingGuideView: View {
    var startTitle = "Got it"
    let onDone: () -> Void
    @State private var page = RecordingGuideView.startPage
    private static var startPage: Int {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-NXPage"), i + 1 < a.count, let n = Int(a[i + 1]) { return n }
        #endif
        return 0
    }

    private struct Page { let overline: String; let title: String; let body: String; let art: AnyView }

    private var pages: [Page] {[
        Page(overline: "Record in NETRIX", title: "Film your game\nat full quality",
             body: "Recording here keeps the original picture and sound, with nothing compressed on upload. That's what lets the analysis track every save.",
             art: AnyView(GuideHeroArt())),
        Page(overline: "Step 1", title: "Set up behind\nyour goalie's net",
             body: "Pick a spot high up at your goalie's end, centred behind the net. Check the glass, netting and posts don't block the crease.",
             art: AnyView(RinkTopDownArt())),
        Page(overline: "Step 2", title: "Get above\nthe glass",
             body: "Two to four metres up works best: the top rows of the stands, a press box or a glass clamp. Higher sees over the players.",
             art: AnyView(SideViewArt())),
        Page(overline: "Step 3", title: "Frame the\ndefensive zone",
             body: "Hold the phone sideways. Put the net in the lower part of the frame and the blue line near the top. Don't zoom or follow the play.",
             art: AnyView(RinkFrameIllustration(showNet: true).clipShape(RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 8))),
        Page(overline: "Step 4", title: "Keep it steady\nand level",
             body: "Use a tripod or clamp, never your hands. The level turns green when it's straight. Tap the net on screen to lock focus.",
             art: AnyView(TripodArt())),
        Page(overline: "Step 5", title: "Before\npuck drop",
             body: "",
             art: AnyView(ChecklistArt())),
        Page(overline: "Step 6", title: "Between\nperiods",
             body: "Teams switch ends after the 1st and 2nd. Stop recording, move the camera behind your goalie's net again, then start the next period.",
             art: AnyView(SwitchEndsArt())),
    ]}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StepBars(total: pages.count, current: page + 1)
                Button("Skip", action: onDone).font(.nxLabel).foregroundStyle(NX.ice).frame(minWidth: 44, minHeight: 44)
                    .opacity(page < pages.count - 1 ? 1 : 0)
            }
            .padding(.horizontal, NX.margin).padding(.top, NX.S.s)
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    ScrollView {
                        VStack(alignment: .leading, spacing: NX.S.m) {
                            pages[i].art.frame(height: 260).frame(maxWidth: .infinity).padding(.vertical, NX.S.s)
                            Overline(pages[i].overline)
                            Text(pages[i].title).font(.sora(28, .bold)).foregroundStyle(.white)
                            if !pages[i].body.isEmpty {
                                Text(pages[i].body).font(.nxBody).foregroundStyle(NX.textSecondary)
                            }
                        }
                        .padding(.horizontal, NX.margin)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            Button(page == pages.count - 1 ? startTitle : "Next") {
                if page < pages.count - 1 { withAnimation { page += 1 } } else { onDone() }
            }
            .buttonStyle(.nxPrimary)
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
        .nxScreen()
        .presentationBackground(NX.base)
    }
}

// MARK: - Illustrations (drawn in code, brand colours)

private let rinkWhite = Color(hex: 0xE9EEF5)
private let lineRed = Color(hex: 0xE5484D)
private let lineBlue = Color(hex: 0x3B6FE0)

/// Phone in landscape showing a recording, with quality chips.
private struct GuideHeroArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(Color(hex: 0x15171D)).frame(width: 300, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(NX.borderStrong, lineWidth: 2))
            RinkFrameIllustration(showNet: true).frame(width: 272, height: 136).clipShape(RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("REC 12:48").font(.sora(10, .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(.black.opacity(0.6)))
            .offset(x: -88, y: -52)
            VStack(spacing: 8) {
                chip("1080p · 60 fps", "sparkles")
                chip("Original quality", "checkmark.seal")
                chip("Game sound on", "waveform")
            }
            .offset(x: 120, y: 92)
        }
        .accessibilityHidden(true)
    }
    private func chip(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(.sora(11, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color(hex: 0x1C2233))).overlay(Capsule().stroke(NX.borderSubtle))
    }
}

/// Top-down half rink with the camera behind the net and its field of view.
private struct RinkTopDownArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, 320), h = geo.size.height * 0.92
            let ox = (geo.size.width - w) / 2, oy = (geo.size.height - h) / 2
            let goalY = oy + h * 0.80, blueY = oy + h * 0.25
            ZStack {
                RoundedRectangle(cornerRadius: 70).fill(rinkWhite).frame(width: w, height: h * 1.4)
                    .position(x: geo.size.width / 2, y: oy + h * 0.7)
                    .mask(Rectangle().frame(width: w, height: h).position(x: geo.size.width / 2, y: oy + h / 2))
                Rectangle().fill(lineBlue).frame(width: w, height: 6).position(x: geo.size.width / 2, y: blueY)
                Rectangle().fill(lineRed).frame(width: w * 0.9, height: 2).position(x: geo.size.width / 2, y: goalY)
                ForEach([-1.0, 1.0], id: \.self) { s in
                    Circle().stroke(lineRed, lineWidth: 2).frame(width: w * 0.3, height: w * 0.3)
                        .position(x: geo.size.width / 2 + s * w * 0.25, y: oy + h * 0.55)
                }
                // Crease and net
                Path { p in
                    p.addArc(center: CGPoint(x: geo.size.width / 2, y: goalY), radius: 26, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                }
                .fill(lineBlue.opacity(0.35))
                RoundedRectangle(cornerRadius: 3).fill(lineRed).frame(width: 34, height: 12).position(x: geo.size.width / 2, y: goalY + 8)
                // Field of view
                Path { p in
                    let cam = CGPoint(x: geo.size.width / 2, y: oy + h + 4)
                    p.move(to: cam)
                    p.addLine(to: CGPoint(x: ox + 4, y: blueY - 10))
                    p.addLine(to: CGPoint(x: ox + w - 4, y: blueY - 10))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [NX.ice.opacity(0.05), NX.ice.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                // Camera
                ZStack {
                    Circle().fill(NX.royal).frame(width: 40, height: 40)
                    Image(systemName: "video.fill").font(.system(size: 15)).foregroundStyle(.white)
                }
                .position(x: geo.size.width / 2, y: oy + h + 4)
                label("Camera: high, centred", y: oy + h + 34, x: geo.size.width / 2)
                label("Blue line", y: blueY - 20, x: ox + 46)
                label("Net", y: goalY + 26, x: geo.size.width / 2 + 40)
            }
        }
        .accessibilityHidden(true)
    }
    private func label(_ t: String, y: CGFloat, x: CGFloat) -> some View {
        Text(t).font(.sora(11, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.7)))
            .position(x: x, y: y)
    }
}

/// Side view: stands, glass, phone on a tripod above the glass, line of sight to the net.
private struct SideViewArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let iceY = h * 0.82
            ZStack {
                // Ice
                Rectangle().fill(rinkWhite).frame(width: w * 0.62, height: 10).position(x: w * 0.35, y: iceY + 5)
                // Net
                Path { p in
                    p.move(to: CGPoint(x: w * 0.20, y: iceY)); p.addLine(to: CGPoint(x: w * 0.20, y: iceY - 26))
                    p.addLine(to: CGPoint(x: w * 0.27, y: iceY - 26)); p.addLine(to: CGPoint(x: w * 0.30, y: iceY))
                }
                .stroke(lineRed, lineWidth: 3)
                // Boards + glass
                Rectangle().fill(Color(hex: 0xC9D2DE)).frame(width: 8, height: 34).position(x: w * 0.68, y: iceY - 12)
                Rectangle().fill(NX.ice.opacity(0.25)).frame(width: 6, height: 70).position(x: w * 0.68, y: iceY - 64)
                    .overlay(Rectangle().stroke(NX.ice.opacity(0.6), lineWidth: 1).frame(width: 6, height: 70).position(x: w * 0.68, y: iceY - 64))
                // Stands (steps)
                let step = (w * 0.2) / 6
                Path { p in
                    var x = w * 0.72, y = iceY
                    p.move(to: CGPoint(x: x, y: y))
                    for _ in 0..<6 { y -= 22; p.addLine(to: CGPoint(x: x, y: y)); x += step; p.addLine(to: CGPoint(x: x, y: y)) }
                    p.addLine(to: CGPoint(x: x, y: iceY)); p.closeSubpath()
                }
                .fill(Color(hex: 0x2A3142))
                // Phone on tripod at top of stands
                let camX = w * 0.72 + step * 5.5, camY = iceY - 22 * 6 - 34
                Path { p in
                    p.move(to: CGPoint(x: camX, y: camY + 10)); p.addLine(to: CGPoint(x: camX - 12, y: camY + 34))
                    p.move(to: CGPoint(x: camX, y: camY + 10)); p.addLine(to: CGPoint(x: camX + 12, y: camY + 34))
                    p.move(to: CGPoint(x: camX, y: camY + 10)); p.addLine(to: CGPoint(x: camX, y: camY + 34))
                }
                .stroke(Color.white.opacity(0.8), lineWidth: 2)
                RoundedRectangle(cornerRadius: 3).fill(NX.royal).frame(width: 26, height: 14).position(x: camX, y: camY)
                // Line of sight
                Path { p in p.move(to: CGPoint(x: camX - 12, y: camY + 2)); p.addLine(to: CGPoint(x: w * 0.25, y: iceY - 14)) }
                    .stroke(NX.ice, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                // Height marker
                Path { p in p.move(to: CGPoint(x: w * 0.97, y: iceY)); p.addLine(to: CGPoint(x: w * 0.97, y: camY)) }
                    .stroke(NX.cream.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Text("2–4 m").font(.sora(11, .semibold)).foregroundStyle(NX.cream)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.black.opacity(0.7)))
                    .position(x: w * 0.97 - 22, y: camY - 18)
                Text("Sees over the glass and players").font(.sora(11, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.7)))
                    .position(x: w * 0.42, y: h * 0.18)
            }
        }
        .accessibilityHidden(true)
    }
}

/// What the camera should see: the defensive zone in perspective, net low and centred.
struct RinkFrameIllustration: View {
    var showNet = true
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x2A3142), Color(hex: 0x1A1F2B)], startPoint: .top, endPoint: .bottom)
                // Ice in perspective (far edge narrower)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.18, y: h * 0.08)); p.addLine(to: CGPoint(x: w * 0.82, y: h * 0.08))
                    p.addLine(to: CGPoint(x: w * 1.02, y: h * 1.0)); p.addLine(to: CGPoint(x: -w * 0.02, y: h * 1.0)); p.closeSubpath()
                }
                .fill(rinkWhite)
                // Blue line near the top
                Path { p in p.move(to: CGPoint(x: w * 0.165, y: h * 0.16)); p.addLine(to: CGPoint(x: w * 0.835, y: h * 0.16)) }
                    .stroke(lineBlue, lineWidth: max(3, h * 0.025))
                // Faceoff circles
                ForEach([0.3, 0.7], id: \.self) { fx in
                    Ellipse().stroke(lineRed, lineWidth: 2).frame(width: w * 0.2, height: h * 0.16).position(x: w * fx, y: h * 0.45)
                }
                // Goal line, crease, net
                Path { p in p.move(to: CGPoint(x: w * 0.04, y: h * 0.8)); p.addLine(to: CGPoint(x: w * 0.96, y: h * 0.8)) }
                    .stroke(lineRed, lineWidth: 2)
                Ellipse().fill(lineBlue.opacity(0.35)).frame(width: w * 0.16, height: h * 0.1).position(x: w / 2, y: h * 0.77)
                if showNet {
                    RoundedRectangle(cornerRadius: 3).stroke(lineRed, lineWidth: 3).frame(width: w * 0.1, height: h * 0.09).position(x: w / 2, y: h * 0.83)
                    Image(systemName: "figure.hockey").font(.system(size: h * 0.14)).foregroundStyle(NX.navy).position(x: w / 2, y: h * 0.72)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Phone on a tripod with a level bubble.
private struct TripodArt: View {
    var body: some View {
        ZStack {
            // Tripod legs
            Path { p in
                p.move(to: CGPoint(x: 160, y: 120)); p.addLine(to: CGPoint(x: 100, y: 240))
                p.move(to: CGPoint(x: 160, y: 120)); p.addLine(to: CGPoint(x: 220, y: 240))
                p.move(to: CGPoint(x: 160, y: 120)); p.addLine(to: CGPoint(x: 160, y: 240))
            }
            .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 30, height: 12).position(x: 160, y: 116)
            // Phone in landscape
            RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x15171D)).frame(width: 190, height: 96)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(NX.borderStrong, lineWidth: 2))
                .overlay(RinkFrameIllustration().frame(width: 172, height: 80).clipShape(RoundedRectangle(cornerRadius: 9)))
                .position(x: 160, y: 62)
            // Level
            HStack(spacing: 6) {
                Capsule().fill(NX.success).frame(width: 46, height: 3)
                Text("Level").font(.sora(11, .semibold)).foregroundStyle(NX.success)
            }
            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.black.opacity(0.7)))
            .position(x: 160, y: 62)
            Label("Tap net to lock focus", systemImage: "hand.tap").font(.sora(11, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(NX.royal))
                .position(x: 250, y: 150)
        }
        .frame(width: 320, height: 250)
        .accessibilityHidden(true)
    }
}

private struct ChecklistArt: View {
    private let items: [(String, String, String)] = [
        ("battery.100.bolt", "Charge to 80%+ or bring a battery pack", "A full game uses a lot of battery."),
        ("internaldrive", "Free up storage", "About 6 GB per hour at 1080p · 60 fps."),
        ("moon.fill", "Turn on Do Not Disturb", "So calls and alerts don't interrupt the recording."),
        ("sparkles", "Wipe the lens", "Smudges blur the puck."),
        ("checkmark.shield", "Check the rink allows filming", "Some arenas and leagues have rules."),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items, id: \.1) { icon, title, sub in
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(NX.ice)
                        .frame(width: 36, height: 36).background(Circle().fill(NX.ice.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.sora(14, .semibold)).foregroundStyle(.white)
                        Text(sub).font(.sora(12)).foregroundStyle(NX.textMuted)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

/// Two rink halves with the goalie's net switching ends, and the camera following.
private struct SwitchEndsArt: View {
    var body: some View {
        HStack(spacing: 14) {
            end(period: "1st & 3rd periods", left: true)
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 22, weight: .semibold)).foregroundStyle(NX.ice)
            end(period: "2nd period", left: false)
        }
        .accessibilityHidden(true)
    }
    private func end(period: String, left: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(rinkWhite).frame(width: 130, height: 180)
                Rectangle().fill(lineRed).frame(width: 130, height: 3).position(x: 65, y: 90)
                Rectangle().fill(lineBlue).frame(width: 130, height: 4).position(x: 65, y: left ? 62 : 118)
                RoundedRectangle(cornerRadius: 2).fill(lineRed).frame(width: 26, height: 9).position(x: 65, y: left ? 162 : 18)
                ZStack {
                    Circle().fill(NX.royal).frame(width: 30, height: 30)
                    Image(systemName: "video.fill").font(.system(size: 12)).foregroundStyle(.white)
                }
                .position(x: 65, y: left ? 196 : -16)
            }
            .frame(width: 130, height: 180)
            .padding(.vertical, 18)
            Text(period).font(.sora(12, .semibold)).foregroundStyle(.white)
        }
    }
}
