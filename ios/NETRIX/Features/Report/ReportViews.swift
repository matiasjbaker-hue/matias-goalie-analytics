import SwiftUI

/// Ring fill for a save percentage: 80% (empty) to 100% (full), the range goalies live in.
func svRingFraction(_ sv: Double?) -> Double { sv.map { ($0 - 80) / 20 } ?? 0 }

// MARK: 06.05 Game summary

struct GameSummaryView: View {
    let metrics: GameMetrics
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GoalieStore

    private var seasonAvg: SummaryMetrics { SummaryMetrics(games: store.seasonGames.filter { $0.game.id != metrics.game.id }) }

    var body: some View {
        VStack(spacing: 0) {
            AppBar(title: "Game summary", onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    GameTitle(metrics: metrics, profile: store.profile)
                    RingCard(metrics: metrics, season: seasonAvg)
                    StatGrid(metrics: metrics, season: seasonAvg)
                    Text("Analysis report").font(.nxH2).foregroundStyle(.white).padding(.top, NX.S.s)
                    VStack(spacing: NX.S.s) {
                        NavigationLink(value: AppRoute.report(metrics)) { ListRow(icon: "chart.pie", title: "Overview & shot quality") }
                        NavigationLink(value: AppRoute.skills) { ListRow(icon: "chart.bar.xaxis", title: "Skills over time") }
                        NavigationLink(value: AppRoute.patterns) { ListRow(icon: "list.bullet.rectangle", title: "Recurring patterns") }
                    }
                    .buttonStyle(.plain)
                    NavigationLink(value: AppRoute.report(metrics)) {
                        Text("Open full report").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.nxPrimary)
                    .padding(.top, NX.S.s)
                }
                .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xxl)
            }
        }
        .nxScreen()
    }
}

struct GameTitle: View {
    let metrics: GameMetrics
    let profile: Profile?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("vs \(metrics.game.opponentName)").font(.nxH1).foregroundStyle(.white)
            Text(meta).font(.nxBodyS).foregroundStyle(NX.textMuted)
        }
        .padding(.top, NX.S.s)
    }
    private var meta: String {
        var parts: [String] = []
        if let d = metrics.game.date { parts.append(Fmt.shortDate.string(from: d)) }
        if let l = profile?.level { parts.append(l) }
        if let h = metrics.game.homeAway, !h.isEmpty { parts.append(h.capitalized) }
        if let t = metrics.game.teamGoals, let o = metrics.game.opponentGoals { parts.append("\(t)–\(o) \(t > o ? "W" : (t < o ? "L" : "T"))") }
        return parts.joined(separator: " · ")
    }
}

private struct RingCard: View {
    let metrics: GameMetrics
    let season: SummaryMetrics
    var body: some View {
        HStack(spacing: NX.S.xl) {
            ScoreRing(fraction: svRingFraction(metrics.svPct), value: Fmt.pct(metrics.svPct), caption: "Save %", size: 120, lineWidth: 11)
            VStack(alignment: .leading, spacing: 6) {
                Overline("Goals saved above expected", color: NX.textMuted)
                Text(metrics.gsax.map { Fmt.signed($0) } ?? "—").font(.sora(28, .bold)).foregroundStyle(.white)
                if let sv = metrics.svPct, let avg = season.svPct, season.count > 0 {
                    let d = sv - avg
                    Label("\(Fmt.signed(d)) pts vs your season", systemImage: d >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.nxCaption).foregroundStyle(d >= 0 ? NX.success : NX.error)
                        .labelStyle(TightLabel())
                }
                if metrics.taggedShots == 0 {
                    Text("No tagged shots for this game, so shot-quality numbers aren't available.")
                        .font(.nxCaption).foregroundStyle(NX.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .nxCard(radius: 24)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 8)); configuration.title }
    }
}

private struct StatGrid: View {
    let metrics: GameMetrics
    let season: SummaryMetrics
    var body: some View {
        VStack(alignment: .leading, spacing: NX.S.m) {
            Text("Game statistics").font(.nxH2).foregroundStyle(.white).padding(.top, NX.S.s)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: NX.S.m), GridItem(.flexible(), spacing: NX.S.m)], spacing: NX.S.m) {
                StatTile(title: "Save %", value: Fmt.pct(metrics.svPct)) {
                    footer(metrics.svPct.flatMap { sv in season.svPct.map { "\(Fmt.signed(sv - $0)) vs season" } }, good: (metrics.svPct ?? 0) >= (season.svPct ?? 0))
                }
                StatTile(title: "Shots faced", value: "\(metrics.shotsAgainst)") {
                    footer(season.shotsPerGame.map { "Season avg \(Fmt.num($0, digits: 0))" }, good: nil)
                }
                StatTile(title: "Saves", value: "\(metrics.saves)") {
                    footer(season.savesPerGame.map { "Season avg \(Fmt.num($0, digits: 1))" }, good: nil)
                }
                StatTile(title: "Goals against", value: "\(metrics.goals)") {
                    footer(season.goalsPerGame.map { "Season avg \(Fmt.num($0, digits: 1))" }, good: nil)
                }
            }
        }
    }
    @ViewBuilder private func footer(_ text: String?, good: Bool?) -> some View {
        if let text, season.count > 0 {
            Text(text).font(.nxCaption).foregroundStyle(good == nil ? NX.success.opacity(0.85) : (good! ? NX.success : NX.error))
        } else {
            Text("First game of the season").font(.nxCaption).foregroundStyle(NX.textMuted)
        }
    }
}

// MARK: 05.01 Report overview

struct GameReportView: View {
    let metrics: GameMetrics
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GoalieStore

    private var season: SummaryMetrics { SummaryMetrics(games: store.seasonGames.filter { $0.game.id != metrics.game.id }) }
    @State private var pdfURL: URL?
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            AppBar(title: "Game report", onBack: { dismiss() }) {
                if let pdfURL {
                    ShareLink(item: pdfURL) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(Circle().fill(Color.white.opacity(0.08)))
                            .overlay(Circle().stroke(NX.borderSubtle))
                    }
                    .accessibilityLabel("Share report as PDF")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    GameTitle(metrics: metrics, profile: store.profile)
                    RingCard(metrics: metrics, season: season)
                    StatGrid(metrics: metrics, season: season)
                    GameFilmSection(metrics: metrics).padding(.top, NX.S.s)

                    SectionHeader(title: "Shot quality", action: "Over time") {}
                        .overlay(alignment: .trailing) { NavigationLink(value: AppRoute.skills) { Color.clear.frame(width: 100, height: 30) } }
                        .padding(.top, NX.S.s)
                    VStack(spacing: NX.S.l) {
                        MeterRow(title: "High-danger save %", valueText: Fmt.pct(metrics.highDangerSvPct, digits: 0), fraction: (metrics.highDangerSvPct ?? 0) / 100)
                        MeterRow(title: "Rebound control", valueText: Fmt.pct(metrics.reboundGoodPct, digits: 0), fraction: (metrics.reboundGoodPct ?? 0) / 100)
                        MeterRow(title: "Expected save %", valueText: Fmt.pct(metrics.expectedSvPct, digits: 1), fraction: svRingFraction(metrics.expectedSvPct))
                        MeterRow(title: "Actual save %", valueText: Fmt.pct(metrics.svPct, digits: 1), fraction: svRingFraction(metrics.svPct))
                    }
                    .nxCard(radius: 20)

                    if !metrics.gradeCounts.isEmpty {
                        Text("Shots by grade").font(.nxH3).foregroundStyle(.white).padding(.top, NX.S.s)
                        VStack(spacing: 0) {
                            ForEach(["A+", "A", "B", "C"].filter { metrics.gradeCounts[$0] != nil }, id: \.self) { g in
                                let c = metrics.gradeCounts[g]!
                                HStack {
                                    Text(g).font(.sora(14, .bold)).foregroundStyle(NX.navy).frame(width: 34, height: 26)
                                        .background(Capsule().fill(g.hasPrefix("A") ? NX.ice : NX.cream))
                                    Text(gradeLabel(g)).font(.nxBodyS).foregroundStyle(NX.textSecondary)
                                    Spacer()
                                    Text("\(c.saves)/\(c.shots) saved").font(.nxLabel).foregroundStyle(.white).monospacedDigit()
                                }
                                .padding(.vertical, 10)
                            }
                        }
                        .nxCard(radius: 20)
                    }

                    let s = strengths
                    if !s.good.isEmpty || !s.work.isEmpty {
                        SectionHeader(title: "Strengths & areas to improve", action: "Patterns") {}
                            .overlay(alignment: .trailing) { NavigationLink(value: AppRoute.patterns) { Color.clear.frame(width: 100, height: 30) } }
                            .padding(.top, NX.S.s)
                        HStack(alignment: .top, spacing: NX.S.m) {
                            column("Strengths", s.good, NX.success)
                            column("To improve", s.work, NX.warning)
                        }
                    }

                    if let note = store.note(for: metrics.game) {
                        VStack(alignment: .leading, spacing: NX.S.s) {
                            Overline("Coach feedback")
                            Text(note.text).font(.nxBody).foregroundStyle(.white.opacity(0.92))
                        }
                        .nxCard(radius: 20)
                    }
                    if app.isCoach { CoachNoteComposer(gameId: metrics.game.id.value) }
                }
                .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xxl)
            }
        }
        .nxScreen()
        .task {
            pdfURL = ReportExporter.pdf(metrics: metrics, season: season, profile: store.profile, note: store.note(for: metrics.game))
        }
    }

    private func gradeLabel(_ g: String) -> String {
        switch g { case "A+": "Highest danger"; case "A": "High danger"; case "B": "Medium danger"; default: "Low danger" }
    }

    private func column(_ title: String, _ items: [String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: NX.S.s) {
            Overline(title, color: color)
            if items.isEmpty { Text("—").font(.nxBodyS).foregroundStyle(NX.textMuted) }
            ForEach(items, id: \.self) { Text($0).font(.nxBodyS).foregroundStyle(.white) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .nxCard(radius: 20)
    }

    /// This game's numbers against the goalie's own season average.
    private var strengths: (good: [String], work: [String]) {
        var good: [String] = [], work: [String] = []
        func cmp(_ name: String, _ v: Double?, _ avg: Double?, tolerance: Double) {
            guard let v, let avg else { return }
            if v >= avg + tolerance { good.append(name) } else if v <= avg - tolerance { work.append(name) }
        }
        guard season.count > 0 else { return ([], []) }
        cmp("Overall save %", metrics.svPct, season.svPct, tolerance: 1)
        cmp("High-danger saves", metrics.highDangerSvPct, season.highDangerSvPct, tolerance: 3)
        cmp("Rebound control", metrics.reboundGoodPct, season.reboundGoodPct, tolerance: 5)
        if let g = metrics.gsax { if g >= 0.5 { good.append("Saves above expected") } else if g <= -0.5 { work.append("Saves below expected") } }
        return (good, work)
    }
}

// MARK: 06.07 Skills over time

struct SkillsOverTimeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GoalieStore
    @State private var period: StatPeriod = .season

    var body: some View {
        let games = store.games(in: period)
        let current = SummaryMetrics(games: Array(games.prefix(5)))
        let previous = SummaryMetrics(games: Array(games.dropFirst(5).prefix(5)))
        let season = SummaryMetrics(games: store.seasonGames)
        VStack(spacing: 0) {
            AppBar(title: "Skill breakdown", onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    Text("Skills over time").font(.nxH1).foregroundStyle(.white).padding(.top, NX.S.s)
                    Text("Your last 5 games compared with the 5 before.").font(.nxBodyS).foregroundStyle(NX.textMuted)
                    PillSegment(options: StatPeriod.allCases, selection: $period, title: { $0.rawValue })
                    if games.isEmpty {
                        EmptyStateCard(icon: "chart.bar", title: "No games in this period", message: "Pick a longer period to see your trends.")
                    } else {
                        skill("Overall save %", current.svPct, previous.svPct, season.svPct, digits: 1, frac: svRingFraction)
                        skill("High-danger save %", current.highDangerSvPct, previous.highDangerSvPct, season.highDangerSvPct, digits: 0) { $0 / 100 }
                        skill("Rebound control", current.reboundGoodPct, previous.reboundGoodPct, season.reboundGoodPct, digits: 0) { $0 / 100 }
                        skill("Expected save %", current.expectedSvPct, previous.expectedSvPct, season.expectedSvPct, digits: 1, frac: svRingFraction)
                    }
                }
                .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xxl)
            }
        }
        .nxScreen()
    }

    @ViewBuilder
    private func skill(_ title: String, _ cur: Double?, _ prev: Double?, _ season: Double?, digits: Int, frac: @escaping (Double) -> Double) -> some View {
        VStack(alignment: .leading, spacing: NX.S.m) {
            HStack {
                Text(title).font(.nxH3).foregroundStyle(.white)
                Spacer()
                if let cur, let prev {
                    DeltaChip(text: "\(Fmt.num(abs(cur - prev), digits: digits)) pts",
                              positive: abs(cur - prev) < 0.05 ? nil : cur >= prev)
                }
            }
            MeterRow(title: "Last 5 games", valueText: Fmt.pct(cur, digits: digits), fraction: cur.map(frac) ?? 0)
            Text("Season \(Fmt.pct(season, digits: digits))\(prev != nil ? " · Previous 5 \(Fmt.pct(prev, digits: digits))" : "")")
                .font(.nxCaption).foregroundStyle(NX.textMuted)
        }
        .nxCard(radius: 20)
    }
}

// MARK: 06.08 Recurring patterns

struct PatternsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GoalieStore

    struct Pattern: Identifiable { let id = UUID(); let title: String; let seen: Int; let of: Int }

    /// Across the last 5 games: how often each number beat (or fell short of) the goalie's season average.
    private var patterns: (good: [Pattern], work: [Pattern]) {
        let recent = Array(store.games.prefix(5))
        let season = SummaryMetrics(games: store.seasonGames)
        guard recent.count >= 3 else { return ([], []) }
        var good: [Pattern] = [], work: [Pattern] = []
        func check(_ name: String, _ bad: String, _ value: (GameMetrics) -> Double?, _ avg: Double?) {
            guard let avg else { return }
            let vals = recent.compactMap(value)
            guard vals.count >= 3 else { return }
            let above = vals.filter { $0 >= avg }.count
            if above * 2 > vals.count { good.append(Pattern(title: name, seen: above, of: vals.count)) }
            else { work.append(Pattern(title: bad, seen: vals.count - above, of: vals.count)) }
        }
        check("Save % at or above your season average", "Save % below your season average", { $0.svPct }, season.svPct)
        check("Strong on high-danger shots", "High-danger shots getting through", { $0.highDangerSvPct }, season.highDangerSvPct)
        check("Controlling rebounds", "Rebounds left in dangerous areas", { $0.reboundGoodPct }, season.reboundGoodPct)
        check("Saving more than expected", "Saving fewer than expected", { $0.gsax }, 0)
        return (good.sorted { $0.seen > $1.seen }, work.sorted { $0.seen > $1.seen })
    }

    var body: some View {
        let p = patterns
        VStack(spacing: 0) {
            AppBar(title: "Patterns", onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.m) {
                    Text("Recurring patterns").font(.nxH1).foregroundStyle(.white).padding(.top, NX.S.s)
                    Text("Seen across your last \(min(5, store.games.count)) analysed games.").font(.nxBodyS).foregroundStyle(NX.textMuted)
                    if p.good.isEmpty && p.work.isEmpty {
                        EmptyStateCard(icon: "chart.line.uptrend.xyaxis", title: "Not enough data yet",
                                       message: "Patterns unlock after 3 analysed games.")
                    } else {
                        if !p.good.isEmpty { Overline("Strengths", color: NX.success).padding(.top, NX.S.s) }
                        ForEach(p.good) { row($0, NX.success) }
                        if !p.work.isEmpty { Overline("Areas to improve", color: NX.warning).padding(.top, NX.S.s) }
                        ForEach(p.work) { row($0, NX.warning) }
                    }
                }
                .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xxl)
            }
        }
        .nxScreen()
    }

    private func row(_ p: Pattern, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Overline("Seen in \(p.seen) of \(p.of) games", color: color)
            Text(p.title).font(.sora(16, .semibold)).foregroundStyle(.white)
        }
        .nxCard(radius: 20)
    }
}
