import SwiftUI
import Charts

/// 06.06 Performance (and 06.09 "not enough data").
struct PerformanceView: View {
    let onSubmit: () -> Void
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: GoalieStore
    @State private var period: StatPeriod = .season

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NX.S.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Performance").font(.nxH1).foregroundStyle(.white)
                    Text("Your progress across analysed games.").font(.nxBodyS).foregroundStyle(NX.textMuted)
                }
                .padding(.top, NX.S.l)
                if !store.hasLoaded && store.isLoading {
                    SkeletonCard(); SkeletonCard()
                } else if store.games.count < 2 {
                    EmptyStateCard(icon: "square.and.arrow.up", title: "Not enough data yet",
                                   message: "Trends unlock after 2 analysed games. You have \(store.games.count) so far.",
                                   actionTitle: "Submit a game", action: onSubmit)
                } else {
                    PillSegment(options: StatPeriod.allCases, selection: $period, title: { $0.rawValue })
                    let games = store.games(in: period)
                    if games.isEmpty {
                        EmptyStateCard(icon: "calendar", title: "No games this \(period.rawValue.lowercased())",
                                       message: "Switch to Season to see all your analysed games.")
                    } else {
                        trendChart(games)
                        averages(games)
                        comparison(games)
                        HStack(spacing: NX.S.s) {
                            NavigationLink(value: AppRoute.skills) { Text("Skills over time") }.buttonStyle(.nxSecondary)
                            NavigationLink(value: AppRoute.patterns) { Text("Patterns") }.buttonStyle(.nxSecondary)
                        }
                    }
                }
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xxl)
        }
        .refreshable { await app.refreshStore() }
        .nxScreen()
    }

    private struct Point: Identifiable { let id: Int; let label: String; let sv: Double }

    private func trendChart(_ games: [GameMetrics]) -> some View {
        let chrono = Array(games.prefix(8).reversed())
        let pts = chrono.enumerated().compactMap { i, g in g.svPct.map { Point(id: i, label: "G\(i + 1)", sv: $0) } }
        let lo = max(70, (pts.map(\.sv).min() ?? 85) - 3), hi = min(100, (pts.map(\.sv).max() ?? 95) + 2)
        return VStack(alignment: .leading, spacing: NX.S.m) {
            HStack {
                Overline("Save % by game", color: NX.textMuted)
                Spacer()
                Text("Last \(pts.count) games").font(.nxCaption).foregroundStyle(NX.textMuted)
            }
            Chart(pts) { p in
                AreaMark(x: .value("Game", p.label), yStart: .value("Min", lo), yEnd: .value("SV%", p.sv))
                    .foregroundStyle(LinearGradient(colors: [NX.ice.opacity(0.35), NX.ice.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Game", p.label), y: .value("SV%", p.sv))
                    .foregroundStyle(NX.ice)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                if p.id == pts.last?.id {
                    PointMark(x: .value("Game", p.label), y: .value("SV%", p.sv))
                        .foregroundStyle(.white).symbolSize(70)
                }
            }
            .chartYScale(domain: lo...hi)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(NX.borderSubtle)
                    AxisValueLabel().foregroundStyle(NX.textMuted).font(.nxCaption)
                }
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().foregroundStyle(NX.textMuted).font(.nxCaption) }
            }
            .frame(height: 170)
            .accessibilityLabel("Save percentage over the last \(pts.count) games")
        }
        .nxCard(radius: 24)
    }

    private func averages(_ games: [GameMetrics]) -> some View {
        let s = SummaryMetrics(games: games)
        let prior = SummaryMetrics(games: Array(store.games.drop(while: { g in games.contains(g) })))
        return VStack(alignment: .leading, spacing: NX.S.m) {
            Text("\(period == .season ? "Season" : period.rawValue) averages").font(.nxH2).foregroundStyle(.white)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: NX.S.m), GridItem(.flexible(), spacing: NX.S.m)], spacing: NX.S.m) {
                StatTile(title: "Save %", value: Fmt.pct(s.svPct)) { delta(s.svPct, prior.svPct, higher: true) }
                StatTile(title: "GSAx", value: Fmt.signed(s.gsax)) {
                    Text("\(s.taggedShots) shots tagged").font(.nxCaption).foregroundStyle(NX.textMuted)
                }
                StatTile(title: "Goals / game", value: Fmt.num(s.goalsPerGame)) { delta(s.goalsPerGame, prior.goalsPerGame, higher: false) }
                StatTile(title: "Games", value: "\(s.count)") {
                    Text("\(s.shotsAgainst) shots faced").font(.nxCaption).foregroundStyle(NX.textMuted)
                }
            }
        }
    }

    @ViewBuilder private func delta(_ v: Double?, _ base: Double?, higher: Bool) -> some View {
        if period != .season, let v, let base {
            let d = v - base
            let good = higher ? d >= 0 : d <= 0
            Label("\(Fmt.num(abs(d))) vs earlier games", systemImage: d >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .labelStyle(TightLabel()).font(.nxCaption).foregroundStyle(good ? NX.success : NX.error)
        } else {
            Text(" ").font(.nxCaption)
        }
    }

    private func comparison(_ games: [GameMetrics]) -> some View {
        let rows = Array(games.prefix(6))
        return VStack(alignment: .leading, spacing: NX.S.m) {
            Text("Game comparison").font(.nxH2).foregroundStyle(.white)
            VStack(spacing: NX.S.l) {
                ForEach(rows, id: \.game.id) { g in
                    NavigationLink(value: AppRoute.game(g)) {
                        MeterRow(title: "vs \(g.game.opponentName)", valueText: Fmt.pct(g.svPct), fraction: svRingFraction(g.svPct))
                    }
                    .buttonStyle(.plain)
                }
            }
            .nxCard(radius: 20)
        }
    }
}
