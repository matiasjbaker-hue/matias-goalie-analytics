import SwiftUI

enum MainTab: Hashable { case home, history, stats, profile }

/// Floating tab bar from the design: a pill with Home / History / Stats / Profile and a
/// separate round "+" that starts a game submission.
struct MainTabView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: GoalieStore
    @State private var tab: MainTab = .home
    @State private var showSubmit = false
    @State private var homePath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var statsPath = NavigationPath()
    @State private var profilePath = NavigationPath()

    /// Detail screens hide the tab bar, as in the designs.
    private var atRoot: Bool {
        switch tab {
        case .home: homePath.isEmpty
        case .history: historyPath.isEmpty
        case .stats: statsPath.isEmpty
        case .profile: profilePath.isEmpty
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .home:
                    NavigationStack(path: $homePath) {
                        HomeView(onSubmit: { showSubmit = true }, onSeeAll: { tab = .history })
                            .withAppDestinations()
                    }
                case .history:
                    NavigationStack(path: $historyPath) { HistoryView(onSubmit: { showSubmit = true }).withAppDestinations() }
                case .stats:
                    NavigationStack(path: $statsPath) { PerformanceView(onSubmit: { showSubmit = true }).withAppDestinations() }
                case .profile:
                    NavigationStack(path: $profilePath) { ProfileView().withAppDestinations() }
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: atRoot ? 76 : 0) }

            if atRoot {
                TabBar(tab: $tab, onPlus: { showSubmit = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: atRoot)
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $showSubmit) {
            SubmitFlowView()
                .environmentObject(app)
                .environmentObject(store)
                .environmentObject(UploadManager.shared)
        }
        .task(id: app.selectedGoalieId) {
            #if DEBUG
            if let screen = AppState.debugScreen { openDebug(screen); return }
            #endif
            await app.refreshStore(force: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .filmUploadFinished)) { _ in
            app.toast = Toast("Game submitted", message: "An analyst will review it shortly.", style: .success)
            Task { await app.refreshStore() }
        }
    }
}

#if DEBUG
extension MainTabView {
    func openDebug(_ screen: String) {
        switch screen {
        case "history": tab = .history
        case "stats": tab = .stats
        case "profile": tab = .profile
        case "submit": showSubmit = true
        case "report": if let g = store.games.first { homePath.append(AppRoute.report(g)) }
        case "summary": if let g = store.games.first { homePath.append(AppRoute.game(g)) }
        case "skills": homePath.append(AppRoute.skills)
        case "patterns": homePath.append(AppRoute.patterns)
        case "progress": if let v = store.requests.first { homePath.append(AppRoute.request(v)) }
        case "account": tab = .profile; profilePath.append(AppRoute.accountSettings)
        default: break
        }
    }
}
#endif

private struct TabBar: View {
    @Binding var tab: MainTab
    let onPlus: () -> Void

    private let items: [(MainTab, String, String)] = [
        (.home, "house", "Home"), (.history, "clock", "History"), (.stats, "chart.bar", "Stats"), (.profile, "person", "Profile"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(items, id: \.0) { item in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = item.0 }
                    } label: {
                        Image(systemName: item.1)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(tab == item.0 ? .white : NX.textMuted)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background {
                                if tab == item.0 {
                                    Capsule().fill(Color.white.opacity(0.1))
                                        .overlay(Capsule().stroke(NX.borderSubtle))
                                        .padding(.horizontal, 4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.2)
                    .accessibilityAddTraits(tab == item.0 ? .isSelected : [])
                }
            }
            .padding(6)
            .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
            .background(Capsule().fill(Color(hex: 0x12141A).opacity(0.85)))
            .overlay(Capsule().stroke(NX.borderSubtle))

            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(Color(hex: 0x12141A).opacity(0.95)))
                    .overlay(Circle().stroke(NX.borderStrong))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Submit a game")
        }
        .padding(.horizontal, NX.margin)
        .padding(.bottom, 4)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }
}

// MARK: - Shared navigation destinations

enum AppRoute: Hashable {
    case game(GameMetrics)
    case request(GameVideo)
    case report(GameMetrics)
    case skills
    case patterns
    case personalInfo, athleteInfo, teamLevel, notifications, accountSettings, help
}

extension View {
    func withAppDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .game(let m): GameSummaryView(metrics: m)
            case .request(let v): AnalysisProgressView(video: v)
            case .report(let m): GameReportView(metrics: m)
            case .skills: SkillsOverTimeView()
            case .patterns: PatternsView()
            case .personalInfo: PersonalInfoView()
            case .athleteInfo: AthleteInfoView()
            case .teamLevel: TeamLevelEditView()
            case .notifications: NotificationsView()
            case .accountSettings: AccountSettingsView()
            case .help: HelpView()
            }
        }
    }
}
