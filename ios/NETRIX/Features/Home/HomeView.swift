import SwiftUI

/// 03 — Home dashboard ("Home A · Score hero"), with the empty, loading and error states.
struct HomeView: View {
    let onSubmit: () -> Void
    let onSeeAll: () -> Void
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: GoalieStore
    @EnvironmentObject private var uploads: UploadManager
    @State private var period: StatPeriod = .season

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NX.S.xxl) {
                HomeHeader()
                CoachRoster()
                if uploads.job != nil { UploadStatusCard() }
                content
            }
            .padding(.horizontal, NX.margin)
            .padding(.bottom, NX.S.xxl)
        }
        .refreshable { await app.refreshStore() }
        .nxScreen()
    }

    @ViewBuilder private var content: some View {
        if !store.hasLoaded && store.isLoading {
            VStack(spacing: NX.S.l) { SkeletonCard(); SkeletonCard() }
        } else if let error = store.error, !store.hasLoaded {
            ErrorStateCard(message: error.localizedDescription) { Task { await app.refreshStore() } }
        } else if store.games.isEmpty {
            emptyHero
            if !store.entries.isEmpty { recent }
        } else {
            hero
            season
            if let note = store.latestNote { NoteCard(note: note) }
            recent
        }
    }

    // MARK: Hero

    private var seasonSummary: SummaryMetrics { SummaryMetrics(games: store.seasonGames) }

    private var hero: some View {
        let s = seasonSummary
        let sv = s.svPct
        return VStack(spacing: NX.S.l) {
            ZStack {
                TickDial(fraction: sv.map { ($0 - 80) / 20 } ?? 0)
                    .frame(width: 250, height: 250)
                VStack(spacing: 4) {
                    Text(Fmt.pct(sv)).font(.sora(64, .light)).foregroundStyle(.white).monospacedDigit()
                    Text("Season save %").font(.nxBodyS).foregroundStyle(NX.textSecondary)
                    if let g = s.gsax {
                        HStack(spacing: 6) {
                            Image(systemName: g >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8))
                                .foregroundStyle(g >= 0 ? NX.success : NX.error)
                            Text("\(Fmt.signed(g)) goals saved above expected").font(.nxCaption).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .overlay(Capsule().stroke(NX.borderSubtle))
                        .padding(.top, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            HStack(spacing: 0) {
                heroStat(Fmt.pct(s.highDangerSvPct, digits: 0), "High-danger SV%")
                Divider().frame(height: 32).overlay(NX.borderSubtle)
                heroStat(Fmt.pct(s.reboundGoodPct, digits: 0), "Rebound control")
                Divider().frame(height: 32).overlay(NX.borderSubtle)
                heroStat(Fmt.num(s.gaa, digits: 2), "GAA")
            }
        }
        .padding(.top, NX.S.s)
    }

    private func heroStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.sora(20, .semibold)).foregroundStyle(.white).monospacedDigit()
            Text(label).font(.nxCaption).foregroundStyle(NX.textMuted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var emptyHero: some View {
        let waiting = !store.requests.isEmpty
        return VStack(spacing: NX.S.l) {
            ZStack {
                Circle().fill(RadialGradient(colors: [NX.royal, NX.navy.opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: 46))
                    .frame(width: 92, height: 92)
                Image(systemName: waiting ? "hourglass" : "square.and.arrow.up").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
            }
            Text(waiting ? "Your analysis is on the way" : "Submit game footage").font(.sora(24, .semibold)).foregroundStyle(.white)
            Text(waiting ? "An analyst is reviewing your film. Your stats appear here once the report is ready."
                         : "Get a professional analysis of your game from a NETRIX analyst.")
                .font(.nxBody).foregroundStyle(NX.textSecondary).multilineTextAlignment(.center)
            Button(waiting ? "Submit another game" : "Submit a game", action: onSubmit).buttonStyle(.nxPrimary)
                .padding(.top, NX.S.s)
            if !waiting {
                VStack(spacing: 6) {
                    Text("No analysis yet").font(.nxH3).foregroundStyle(.white)
                    Text("Your score, stats and coach feedback will appear here after your first game.")
                        .font(.nxBodyS).foregroundStyle(NX.textMuted).multilineTextAlignment(.center)
                }
                .padding(.top, NX.S.x3)
            }
        }
        .padding(.vertical, NX.S.xxl)
        .frame(maxWidth: .infinity)
    }

    // MARK: This season

    private var season: some View {
        let games = store.games(in: period)
        let s = SummaryMetrics(games: games)
        let chrono = games.reversed()
        let prior = SummaryMetrics(games: Array(store.seasonGames.dropFirst(min(3, store.seasonGames.count))))
        let last3 = SummaryMetrics(games: Array(store.seasonGames.prefix(3)))
        return VStack(alignment: .leading, spacing: NX.S.m) {
            HStack {
                Text("This \(period == .season ? "season" : period.rawValue.lowercased())").font(.nxH3).foregroundStyle(.white)
                Spacer()
                PillSegment(options: [StatPeriod.month, .season], selection: $period, title: { $0.rawValue }, height: 36)
                    .frame(width: 160)
            }
            if games.isEmpty {
                Text("No analysed games in the last \(period == .month ? "30 days" : "7 days").")
                    .font(.nxBodyS).foregroundStyle(NX.textMuted).padding(.vertical, NX.S.l)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: NX.S.m), GridItem(.flexible(), spacing: NX.S.m)], spacing: NX.S.m) {
                    StatTile(title: "Save %", value: Fmt.pct(s.svPct), unit: "%") {
                        trend(last3.svPct, prior.svPct, higherIsBetter: true, digits: 1)
                        Sparkline(values: chrono.compactMap(\.svPct)).frame(height: 34)
                    }
                    StatTile(title: "Goals / game", value: Fmt.num(s.goalsPerGame, digits: 1)) {
                        trend(last3.goalsPerGame, prior.goalsPerGame, higherIsBetter: false, digits: 1)
                        Sparkline(values: chrono.map { Double($0.goals) }).frame(height: 34)
                    }
                    StatTile(title: "Games analysed", value: "\(s.count)", unit: s.count == 1 ? "game" : "games") {
                        DotGrid(count: s.count).frame(height: 40)
                    }
                    StatTile(title: "Shots faced", value: "\(s.shotsAgainst)", unit: "shots") {
                        BarWave(values: chrono.map { Double($0.shotsAgainst) }).frame(height: 40)
                    }
                }
            }
        }
    }

    /// Last 3 games vs the rest of the season, the comparison the website's goalie summary uses.
    @ViewBuilder private func trend(_ recent: Double?, _ base: Double?, higherIsBetter: Bool, digits: Int) -> some View {
        if let recent, let base, store.seasonGames.count >= 4 {
            let diff = recent - base
            let good = higherIsBetter ? diff >= 0 : diff <= 0
            HStack(spacing: 4) {
                Image(systemName: diff >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 9, weight: .bold))
                Text(Fmt.num(abs(diff), digits: digits)).font(.sora(12, .semibold))
            }
            .foregroundStyle(good ? NX.success : NX.error)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill((good ? NX.success : NX.error).opacity(0.14)))
            .accessibilityLabel("Last 3 games \(diff >= 0 ? "up" : "down") \(Fmt.num(abs(diff), digits: digits))")
        } else {
            Text(" ").font(.sora(12)).padding(.vertical, 4)
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: NX.S.m) {
            SectionHeader(title: "Recent analysis", action: "See all", onAction: onSeeAll)
            VStack(spacing: 0) {
                ForEach(Array(store.entries.prefix(3).enumerated()), id: \.element.id) { i, entry in
                    NavigationLink(value: route(for: entry)) {
                        GameRow(entry: entry, subtitle: subtitle(for: entry))
                    }
                    .buttonStyle(.plain)
                    if i < min(3, store.entries.count) - 1 { Divider().overlay(NX.borderSubtle) }
                }
            }
            .padding(.horizontal, NX.S.m)
            .nxCard(padding: 0, radius: 20)
        }
    }

    private func route(for e: GameEntry) -> AppRoute {
        if let m = e.metrics { return .game(m) }
        return .request(e.video!)
    }

    private func subtitle(for e: GameEntry) -> String {
        let date = e.date.map { Fmt.shortDate.string(from: $0) } ?? ""
        let level = store.profile?.level.map { " · \($0)" } ?? ""
        return date + level
    }
}

struct HomeHeader: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: GoalieStore

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h { case 5..<12: return "Good morning"; case 12..<18: return "Good afternoon"; default: return "Good evening" }
    }

    var body: some View {
        HStack(spacing: NX.S.m) {
            AvatarView(profile: app.me, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting).font(.nxCaption).foregroundStyle(NX.textSecondary)
                Text(app.me?.fullName ?? "Welcome").font(.sora(17, .semibold)).foregroundStyle(.white).lineLimit(1)
            }
            Spacer()
            if app.isCoach { GoaliePicker() }
            NavigationLink(value: AppRoute.inbox) {
                Image(systemName: "bell")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().stroke(NX.borderSubtle, lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        if store.unreadCount > 0 { Circle().fill(NX.ice).frame(width: 8, height: 8).offset(x: -8, y: 8) }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.unreadCount > 0 ? "Notifications, \(store.unreadCount) new" : "Notifications")
        }
        .padding(.top, NX.S.s)
    }
}

/// Coaches switch between their assigned goalies here.
struct GoaliePicker: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        Menu {
            ForEach(app.coachGoalies) { g in
                Button { app.selectedGoalieId = g.id } label: {
                    if g.id == app.selectedGoalieId { Label(g.fullName ?? "Goalie", systemImage: "checkmark") }
                    else { Text(g.fullName ?? "Goalie") }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(app.selectedGoalie?.fullName ?? "Pick a goalie").font(.nxLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(NX.borderSubtle))
        }
        .disabled(app.coachGoalies.isEmpty)
    }
}

/// Latest coach note (stands in for the comp's "AI insight" card: coach notes are real feedback in the data).
struct NoteCard: View {
    let note: CoachNote
    var body: some View {
        VStack(alignment: .leading, spacing: NX.S.m) {
            HStack(spacing: NX.S.m) {
                Circle().fill(RadialGradient(colors: [NX.ice, NX.royal, NX.navy], center: .center, startRadius: 2, endRadius: 22))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Overline("Coach feedback")
                    Text(Fmt.relative(note.createdAt)).font(.nxCaption).foregroundStyle(NX.textMuted)
                }
            }
            Text(note.text).font(.nxBodyL).foregroundStyle(.white.opacity(0.92)).lineLimit(6)
        }
        .nxCard(radius: 24)
    }
}

struct DotGrid: View {
    let count: Int
    var body: some View {
        let cols = 8, rows = 3
        VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(0..<cols, id: \.self) { c in
                        let i = r * cols + c
                        RoundedRectangle(cornerRadius: 2).fill(i < count ? NX.ice.opacity(0.9) : NX.royal.opacity(0.3))
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct BarWave: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(values.suffix(16).enumerated()), id: \.offset) { _, v in
                    Capsule().fill(LinearGradient(colors: [NX.ice, NX.royal], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: max(4, geo.size.height * CGFloat(v / maxV)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

/// Upload progress / result banner shown on Home while film is going up.
struct UploadStatusCard: View {
    @EnvironmentObject private var uploads: UploadManager
    var body: some View {
        if let job = uploads.job {
            HStack(spacing: NX.S.m) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
                    Circle().trim(from: 0, to: uploads.progress).stroke(stateColor(job.state), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: icon(job.state)).font(.system(size: 12, weight: .bold)).foregroundStyle(stateColor(job.state))
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(job)).font(.nxLabel).foregroundStyle(.white)
                    Text(job.errorMessage ?? "vs \(job.requested?.opponent ?? "your game")").font(.nxCaption).foregroundStyle(NX.textMuted).lineLimit(2)
                }
                Spacer()
                switch job.state {
                case .failed: Button("Try again") { uploads.retry() }.font(.nxLabel).foregroundStyle(NX.ice)
                case .done: Button { uploads.clearFinished() } label: { Image(systemName: "xmark").foregroundStyle(NX.textMuted).frame(width: 32, height: 32) }
                default: EmptyView()
                }
            }
            .nxCard(padding: 14, radius: NX.R.lg)
        }
    }
    private func title(_ j: UploadManager.Job) -> String {
        switch j.state {
        case .uploading: return "Uploading… \(Int(uploads.progress * 100))%"
        case .finishing: return "Finishing upload…"
        case .done: return "Upload complete"
        case .failed: return "Upload failed"
        }
    }
    private func icon(_ s: UploadManager.State) -> String {
        switch s { case .done: "checkmark"; case .failed: "exclamationmark"; default: "arrow.up" }
    }
    private func stateColor(_ s: UploadManager.State) -> Color {
        switch s { case .done: NX.success; case .failed: NX.error; default: NX.ice }
    }
}
