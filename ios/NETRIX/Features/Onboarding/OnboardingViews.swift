import SwiftUI

// MARK: 02.01 Splash

struct SplashView: View {
    @State private var appear = false
    var body: some View {
        ZStack {
            NX.base.ignoresSafeArea()
            RadialGradient(colors: [NX.royal.opacity(0.45), NX.navy.opacity(0.4), .clear],
                           center: .center, startRadius: 0, endRadius: 260)
                .ignoresSafeArea()
                .opacity(appear ? 1 : 0)
            NetrixLockup(height: 24)
                .scaleEffect(appear ? 1 : 0.94)
                .opacity(appear ? 1 : 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { appear = true } }
    }
}

// MARK: 02.02–02.04 Intro carousel

struct IntroView: View {
    let onFinish: () -> Void
    let onLogin: () -> Void
    @State private var page = 0

    private let pages: [(String, String)] = [
        ("Upload your game.\nWe do the rest.", "Submit footage from any rink. NETRIX breaks down every save, rebound and movement."),
        ("Your goaltending,\nmeasured.", "Get a clear read on save percentage, shot quality and rebound control after every game."),
        ("Feedback from\nreal analysts.", "Expert notes on your game, so you know exactly what to work on next."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: onFinish).font(.nxLabel).foregroundStyle(NX.ice).frame(height: 44)
            }
            .padding(.horizontal, NX.margin)
            .opacity(page < pages.count - 1 ? 1 : 0)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 0) {
                        Group {
                            switch i {
                            case 0: IntroUploadArt()
                            case 1: IntroScoreArt()
                            default: IntroAnalystArt()
                            }
                        }
                        .frame(height: 340)
                        .padding(.horizontal, NX.margin)
                        Spacer(minLength: 24)
                        Text(pages[i].0).font(.sora(30, .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                        Text(pages[i].1).font(.nxBody).foregroundStyle(NX.textSecondary).multilineTextAlignment(.center)
                            .padding(.top, NX.S.m).padding(.horizontal, NX.S.x3)
                        Spacer(minLength: 16)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule().fill(i == page ? Color.white : Color.white.opacity(0.25)).frame(width: i == page ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.3), value: page)
            .padding(.bottom, NX.S.xxl)

            Button(page == pages.count - 1 ? "Get started" : "Continue") {
                if page < pages.count - 1 { withAnimation { page += 1 } } else { onFinish() }
            }
            .buttonStyle(.nxPrimary)
            .padding(.horizontal, NX.margin)
            InlinePrompt(text: "Already have an account?", action: "Log in", onTap: onLogin)
                .padding(.bottom, 4)
        }
        .nxScreen()
    }
}

private struct IntroUploadArt: View {
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color(hex: 0xD9DDE3), Color(hex: 0x9AA3AE)], startPoint: .top, endPoint: .bottom))
                        .overlay(Image(systemName: "figure.hockey").font(.system(size: 64)).foregroundStyle(.black.opacity(0.55)))
                        .overlay(Circle().fill(.white).frame(width: 46, height: 46).overlay(Image(systemName: "play.fill").foregroundStyle(.black)))
                    Text("12:48").font(.sora(11, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(.black.opacity(0.55))).padding(10)
                }
                .frame(height: 150)
                Text("vs Lakeside Hawks").font(.sora(16, .semibold)).foregroundStyle(.white)
                HStack { Text("Uploading").foregroundStyle(NX.textMuted); Spacer(); Text("68%").foregroundStyle(NX.ice) }.font(.nxCaption)
                MeterRow(title: "", valueText: "", fraction: 0.68).frame(height: 8)
            }
            .padding(14)
            .nxCard(padding: 0)
            .frame(width: 270)
            .offset(x: 14, y: -10)

            chip(icon: "sparkles", bold: "Every save", text: "tagged")
                .offset(x: 70, y: -162)
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(NX.ice)
                    .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 10).fill(NX.royal.opacity(0.35)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reviewed by").font(.nxCaption).foregroundStyle(NX.textMuted)
                    Text("a real analyst").font(.sora(15, .semibold)).foregroundStyle(.white)
                }
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x141824)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(NX.borderSubtle))
            .offset(x: -62, y: 150)
        }
        .accessibilityHidden(true)
    }
}

private struct IntroScoreArt: View {
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ScoreRing(fraction: 0.82, value: "91.2", caption: "SV%", size: 78, lineWidth: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Season save %").font(.nxCaption).foregroundStyle(NX.textMuted)
                        Text("+2.4 GSAx").font(.sora(20, .bold)).foregroundStyle(.white)
                        Text("goals saved above expected").font(.nxCaption).foregroundStyle(NX.ice)
                    }
                }
                MeterRow(title: "High-danger SV%", valueText: "84", fraction: 0.84)
                MeterRow(title: "Rebound control", valueText: "71", fraction: 0.71)
                MeterRow(title: "Expected SV%", valueText: "89", fraction: 0.89)
            }
            .padding(16).nxCard(padding: 0).frame(width: 290)
            chip(icon: "chart.line.uptrend.xyaxis", bold: "+1.2", text: "vs last game", color: NX.success)
                .offset(x: 80, y: -150)
        }
        .accessibilityHidden(true)
    }
}

private struct IntroAnalystArt: View {
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("A").font(.sora(15, .semibold)).foregroundStyle(NX.navy)
                        .frame(width: 40, height: 40).background(Circle().fill(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your analyst").font(.sora(15, .semibold)).foregroundStyle(.white)
                        Text("Goalie analyst").font(.nxCaption).foregroundStyle(NX.textMuted)
                    }
                    Spacer()
                    Text("2h ago").font(.nxCaption).foregroundStyle(NX.textMuted)
                }
                (Text("Great depth management. Next step: ").foregroundColor(NX.textSecondary)
                 + Text("steer rebounds into the corners.").foregroundColor(.white).bold())
                    .font(.nxBody)
                HStack { tag("Positioning", on: true); tag("Rebounds", on: false) }
            }
            .padding(16).nxCard(padding: 0).frame(width: 300)
            .offset(y: -40)
            chip(icon: "checklist", bold: "3 notes", text: "this game").offset(x: -80, y: -150)
        }
        .accessibilityHidden(true)
    }
    private func tag(_ t: String, on: Bool) -> some View {
        Text(t).font(.sora(12, .medium)).foregroundStyle(on ? NX.ice : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(on ? NX.royal.opacity(0.35) : Color.white.opacity(0.08)))
    }
}

private func chip(icon: String, bold: String, text: String, color: Color = NX.ice) -> some View {
    HStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            .frame(width: 22, height: 22).background(Circle().fill(color.opacity(0.18)))
        (Text(bold).bold().foregroundColor(.white) + Text(" " + text).foregroundColor(NX.textSecondary)).font(.nxCaption)
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(Capsule().fill(Color(hex: 0x141824)))
    .overlay(Capsule().stroke(NX.borderSubtle))
}

// MARK: 02.05 Welcome

struct WelcomeView: View {
    let onLogin: () -> Void
    let onCreate: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NetrixLockup(height: 22).padding(.top, NX.S.l)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(NX.ice).frame(width: 6, height: 6)
                Text("Built only for goaltending").font(.nxCaption).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .padding(.bottom, NX.S.l)
            Overline("Goaltending intelligence").padding(.bottom, NX.S.s)
            Text("Train smarter.\nSave more.").font(.sora(40, .bold)).foregroundStyle(.white)
            Text("Submit your game footage and get professional analysis, coaching feedback and progress tracking built for goalies.")
                .font(.nxBody).foregroundStyle(NX.textSecondary).padding(.top, NX.S.m)
            VStack(spacing: NX.S.m) {
                Button("Log in", action: onLogin).buttonStyle(.nxPrimary)
                Button("Create account", action: onCreate).buttonStyle(.nxSecondary)
            }
            .padding(.top, NX.S.x3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NX.margin)
        .padding(.bottom, NX.S.s)
        .background {
            // Brand backdrop: the oversized mark on royal-to-navy, in place of the comp's
            // placeholder photo (a licensed goalie photo can drop in here later).
            ZStack {
                NX.base
                LinearGradient(colors: [NX.royal.opacity(0.55), NX.navy, NX.base], startPoint: .top, endPoint: .center)
                NetrixMark().fill(Color.white.opacity(0.06))
                    .frame(width: 560, height: 260)
                    .rotationEffect(.degrees(-8))
                    .offset(x: 60, y: -170)
            }
            .ignoresSafeArea()
            .clipped()
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
