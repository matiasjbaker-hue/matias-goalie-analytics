import SwiftUI

// MARK: 06.01–06.04 Game history

struct HistoryView: View {
    let onSubmit: () -> Void
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: GoalieStore
    @State private var query = ""
    @State private var status: GameStatus? = nil
    @State private var showFilters = false
    @State private var range: DateRangeFilter = .season
    @State private var sort: SortOrder = .newest

    enum DateRangeFilter: String, CaseIterable, Identifiable { case days30 = "Last 30 days", months3 = "3 months", season = "This season", all = "All time"; var id: String { rawValue } }
    enum SortOrder: String, CaseIterable, Identifiable { case newest = "Newest", oldest = "Oldest", highestSV = "Highest SV%"; var id: String { rawValue } }

    private var filtered: [GameEntry] {
        var list = store.entries
        if let status { list = list.filter { $0.status == status } }
        let q = query.trimmed.lowercased()
        if !q.isEmpty { list = list.filter { $0.title.lowercased().contains(q) } }
        switch range {
        case .days30: list = list.filter { ($0.date ?? .distantPast) > Date().addingTimeInterval(-30 * 86400) }
        case .months3: list = list.filter { ($0.date ?? .distantPast) > Date().addingTimeInterval(-91 * 86400) }
        case .season:
            let ids = Set(store.seasonGames.map(\.game.id))
            list = list.filter { e in e.metrics.map { ids.contains($0.game.id) } ?? true }
        case .all: break
        }
        switch sort {
        case .newest: list.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldest: list.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        case .highestSV: list.sort { ($0.metrics?.svPct ?? -1) > ($1.metrics?.svPct ?? -1) }
        }
        return list
    }

    private var grouped: [(String, [GameEntry])] {
        if sort == .highestSV { return [("", filtered)] }
        var out: [(String, [GameEntry])] = []
        for e in filtered {
            let key = e.date.map { Fmt.monthYear.string(from: $0).uppercased() } ?? "UNDATED"
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(e) } else { out.append((key, [e])) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NX.S.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Game history").font(.nxH1).foregroundStyle(.white)
                    Text("\(store.entries.count) game\(store.entries.count == 1 ? "" : "s") submitted").font(.nxBodyS).foregroundStyle(NX.textMuted)
                }
                .padding(.top, NX.S.l)
                HStack(spacing: NX.S.s) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(NX.textMuted)
                        TextField("", text: $query, prompt: Text("Search by opponent").foregroundColor(NX.textMuted))
                            .font(.nxBody).foregroundStyle(.white).submitLabel(.search)
                    }
                    .padding(.horizontal, NX.S.l).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: NX.R.lg).fill(NX.field))
                    .overlay(RoundedRectangle(cornerRadius: NX.R.lg).stroke(NX.borderSubtle))
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: NX.R.lg).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: NX.R.lg).stroke(NX.borderSubtle))
                    }
                    .accessibilityLabel("Filters")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NX.S.s) {
                        ChoiceChip(title: "All", selected: status == nil) { status = nil }
                        ForEach([GameStatus.completed, .pending, .inReview, .needsAction]) { s in
                            ChoiceChip(title: s.rawValue, selected: status == s) { status = s }
                        }
                    }
                }
                listContent
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await app.refreshStore() }
        .nxScreen()
        .sheet(isPresented: $showFilters) {
            FilterSheet(status: $status, range: $range, sort: $sort)
                .presentationDetents([.medium])
                .presentationBackground(Color(hex: 0x111318))
                .presentationCornerRadius(28)
        }
    }

    @ViewBuilder private var listContent: some View {
        if !store.hasLoaded && store.isLoading {
            VStack(spacing: NX.S.m) { SkeletonCard(); SkeletonCard() }
        } else if let e = store.error, !store.hasLoaded {
            ErrorStateCard(message: e.localizedDescription) { Task { await app.refreshStore() } }
        } else if store.entries.isEmpty {
            EmptyStateCard(icon: "square.and.arrow.up", title: "No games yet",
                           message: "Submit your first game footage to get a professional analysis.",
                           actionTitle: "Submit a game", action: onSubmit)
        } else if filtered.isEmpty {
            EmptyStateCard(icon: "magnifyingglass", title: "No games found",
                           message: "Try changing your filters or search to see more games.",
                           actionTitle: "Clear filters") { status = nil; query = ""; range = .all; sort = .newest }
        } else {
            ForEach(grouped, id: \.0) { group in
                if !group.0.isEmpty { Overline(group.0, color: NX.textMuted).padding(.top, NX.S.s) }
                ForEach(group.1) { entry in
                    NavigationLink(value: entry.metrics.map { AppRoute.game($0) } ?? AppRoute.request(entry.video!)) {
                        GameRow(entry: entry, subtitle: subtitle(entry))
                            .padding(.horizontal, NX.S.m)
                            .nxCard(padding: 0, radius: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func subtitle(_ e: GameEntry) -> String {
        var parts = [e.date.map { Fmt.shortDate.string(from: $0) } ?? ""]
        if let m = e.metrics, let sv = m.svPct { parts.append("\(Fmt.pct(sv))% SV") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct FilterSheet: View {
    @Binding var status: GameStatus?
    @Binding var range: HistoryView.DateRangeFilter
    @Binding var sort: HistoryView.SortOrder
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: NX.S.l) {
            HStack {
                Text("Filters").font(.nxH2).foregroundStyle(.white)
                Spacer()
                Button("Reset") { status = nil; range = .season; sort = .newest }.font(.nxLabel).foregroundStyle(NX.ice)
            }
            section("Status") {
                ChoiceChip(title: "All", selected: status == nil) { status = nil }
                ForEach(GameStatus.allCases) { s in ChoiceChip(title: s.rawValue, selected: status == s) { status = s } }
            }
            section("Date range") {
                ForEach(HistoryView.DateRangeFilter.allCases) { r in ChoiceChip(title: r.rawValue, selected: range == r) { range = r } }
            }
            section("Sort by") {
                ForEach(HistoryView.SortOrder.allCases) { o in ChoiceChip(title: o.rawValue, selected: sort == o) { sort = o } }
            }
            Spacer()
            Button("Apply filters") { dismiss() }.buttonStyle(.nxPrimary)
        }
        .padding(NX.margin)
    }
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: NX.S.s) {
            Text(title).font(.nxLabel).foregroundStyle(NX.textSecondary)
            FlowLayout { content() }
        }
    }
}

// MARK: 04.08 Analysis progress (film still in review)

struct AnalysisProgressView: View {
    let video: GameVideo
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: GoalieStore

    private var entry: GameEntry { GameEntry(kind: .request(video)) }

    var body: some View {
        VStack(spacing: 0) {
            AppBar(title: "Analysis progress", onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    HStack(spacing: NX.S.m) {
                        FilmThumb(size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.sora(17, .semibold)).foregroundStyle(.white)
                            Text(subtitle).font(.nxCaption).foregroundStyle(NX.textMuted)
                            StatusChip(status: entry.status)
                        }
                        Spacer()
                    }
                    .nxCard(radius: 20)

                    VStack(alignment: .leading, spacing: NX.S.l) {
                        Overline("Status", color: NX.textMuted)
                        StepLine(title: "Submitted",
                                 subtitle: "Footage received" + (video.createdAt.map { " · \(Fmt.dayMonth.string(from: $0)), \($0.formatted(date: .omitted, time: .shortened))" } ?? ""),
                                 state: .done)
                        StepLine(title: "In review", subtitle: video.reviewStatus == .received ? "Waiting for an analyst" : "Analyst is reviewing your game",
                                 state: video.reviewStatus == .received ? .todo : .active)
                        StepLine(title: "Report ready", subtitle: "You will see it in History", state: .todo)
                    }
                    .nxCard(radius: 20)

                    if video.reviewStatus == .needsAttention {
                        HStack(alignment: .top, spacing: NX.S.m) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(NX.error)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Needs your attention").font(.nxLabel).foregroundStyle(.white)
                                Text(video.adminNote ?? "The analyst needs something from you to finish this game. Check your email for details.")
                                    .font(.nxBodyS).foregroundStyle(NX.textSecondary)
                            }
                        }
                        .nxCard(radius: NX.R.lg)
                    } else {
                        HStack(spacing: NX.S.m) {
                            Image(systemName: "questionmark.circle").foregroundStyle(NX.ice)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("What's next").font(.nxLabel).foregroundStyle(.white)
                                Text("Every shot is tagged by an analyst. Your stats appear here as soon as the report is approved.")
                                    .font(.nxCaption).foregroundStyle(NX.textSecondary)
                            }
                        }
                        .nxCard(radius: NX.R.lg)
                    }

                    if let r = video.requested, r.goalie_note != nil || !(r.focus_areas ?? []).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Overline("Your notes", color: NX.textMuted)
                            if let f = r.focus_areas, !f.isEmpty { Text(f.joined(separator: " · ")).font(.nxLabel).foregroundStyle(NX.ice) }
                            if let n = r.goalie_note { Text(n).font(.nxBody).foregroundStyle(NX.textSecondary) }
                        }
                        .nxCard(radius: NX.R.lg)
                    }
                }
                .padding(.horizontal, NX.margin)
            }
            Link(destination: URL(string: "mailto:\(AppConfig.supportEmail)?subject=Game%20analysis%20question")!) {
                Text("Contact support").font(.nxLabel).foregroundStyle(NX.ice).frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.bottom, NX.S.s)
        }
        .nxScreen()
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = entry.date { parts.append(Fmt.shortDate.string(from: d)) }
        if let r = video.requested, let t = r.team_goals, let o = r.opponent_goals { parts.append("\(t)–\(o)") }
        return parts.joined(separator: " · ")
    }
}
