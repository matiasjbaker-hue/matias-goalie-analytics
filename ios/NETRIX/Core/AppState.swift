import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable { case launching, signedOut, setup, signedIn }

    @Published var phase: Phase = .launching
    @Published private(set) var session: AuthSession?
    @Published private(set) var me: Profile?
    /// Goalies a coach can view (their assigned goalies). Empty for goalies.
    @Published private(set) var coachGoalies: [Profile] = []
    /// The goalie whose data the tabs show: yourself, or the goalie a coach picked.
    @Published var selectedGoalieId: String?
    @Published var toast: Toast?
    /// A screen to open once signed in (from a notification, widget, Shortcut or link).
    @Published var pendingRoute: String?

    let store = GoalieStore()

    var isCoach: Bool { me?.role == .coach }
    var selectedGoalie: Profile? {
        if let id = selectedGoalieId, id != me?.id { return coachGoalies.first { $0.id == id } }
        return me
    }

    func bootstrap() async {
        #if DEBUG
        if let screen = Self.debugScreen {
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation { applyDebugScreen(screen) }
            return
        }
        #endif
        let started = Date()
        let restored = await SupabaseClient.shared.session
        if restored != nil {
            do {
                session = try await SupabaseClient.shared.validSession()
                try await loadMe()
            } catch {
                session = nil
            }
        }
        // Keep the splash up long enough to read the mark.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 1.2 { try? await Task.sleep(nanoseconds: UInt64((1.2 - elapsed) * 1_000_000_000)) }
        routeAfterAuth()
        if phase == .signedIn { UploadManager.shared.resumeIfNeeded() }
    }

    func signedIn(_ new: AuthSession) async {
        session = new
        do { try await loadMe() } catch { toast = Toast(error.localizedDescription, style: .error) }
        routeAfterAuth()
    }

    func loadMe() async throws {
        guard let uid = await SupabaseClient.shared.session?.user.id else { throw AppError.signedOut }
        let rows: [Profile] = try await SupabaseClient.shared.select("profiles", query: "id=eq.\(uid)&select=*")
        // The database creates the profile on sign-up; a brief delay is possible.
        if rows.isEmpty {
            try? await Task.sleep(nanoseconds: 800_000_000)
            let retry: [Profile] = try await SupabaseClient.shared.select("profiles", query: "id=eq.\(uid)&select=*")
            me = retry.first
        } else {
            me = rows.first
        }
        if me?.role == .coach { await loadCoachGoalies() }
        if selectedGoalieId == nil || (selectedGoalieId != me?.id && !coachGoalies.contains(where: { $0.id == selectedGoalieId })) {
            selectedGoalieId = me?.role == .coach ? (coachGoalies.first?.id ?? me?.id) : me?.id
        }
    }

    private func loadCoachGoalies() async {
        guard let myId = me?.id else { return }
        // A coach can only read profiles of goalies assigned to them (RLS), so every
        // profile that isn't their own is one of their goalies.
        let all: [Profile] = (try? await SupabaseClient.shared.select("profiles", query: "select=*&order=full_name.asc")) ?? []
        coachGoalies = all.filter { $0.id != myId }
    }

    func profileUpdated() async {
        try? await loadMe()
        routeAfterAuth()
    }

    private func routeAfterAuth() {
        withAnimation(.easeInOut(duration: 0.35)) {
            if session == nil || me == nil { phase = .signedOut }
            else if me?.needsSetup == true { phase = .setup }
            else { phase = .signedIn }
        }
    }

    func signOut() async {
        await SupabaseClient.shared.signOut()
        WidgetBridge.clear()
        session = nil; me = nil; coachGoalies = []; selectedGoalieId = nil
        store.reset()
        withAnimation { phase = .signedOut }
    }

    func accountDeleted() async {
        await SupabaseClient.shared.clearLocalSession()
        WidgetBridge.clear()
        session = nil; me = nil; coachGoalies = []; selectedGoalieId = nil
        store.reset()
        withAnimation { phase = .signedOut }
        toast = Toast("Your account was deleted.", style: .success)
    }

    func refreshStore(force: Bool = true) async {
        guard let id = selectedGoalieId else { return }
        await store.load(goalieId: id, force: force)
        if store.error == .signedOut { await signOut() }
    }
}

extension AppState {
    /// netrix://submit, netrix://history, netrix://stats, netrix://inbox, netrix://game/<id>
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "netrix" else { return }
        var route = url.host ?? "home"
        if let id = url.pathComponents.dropFirst().first { route += ":\(id)" }
        pendingRoute = route
    }
}

struct Toast: Identifiable, Equatable {
    enum Style { case success, error, info }
    let id = UUID()
    let title: String
    var message: String? = nil
    let style: Style
    init(_ title: String, message: String? = nil, style: Style = .info) {
        self.title = title; self.message = message; self.style = style
    }
}

#if DEBUG
extension AppState {
    /// Debug-only: `-NXScreen <name>` opens a screen with sample data (no network, no account).
    static var debugScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-NXScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func applyDebugScreen(_ screen: String) {
        let json = #"[{"id":"sample","full_name":"Alex Morgan","role":"goalie","team":"Northside Wolves","season":"2026-27","level":"U18 · AAA / Elite","catches":"L"}]"#
        me = (try? JSONDecoder().decode([Profile].self, from: Data(json.utf8)))?.first
        selectedGoalieId = "sample"
        switch screen {
        case "intro": UserDefaults.standard.set(false, forKey: "seenIntro"); phase = .signedOut
        case "welcome", "login", "signup": UserDefaults.standard.set(true, forKey: "seenIntro"); phase = .signedOut
        case "setup": phase = .setup
        default:
            store.loadSample(empty: screen == "empty")
            phase = .signedIn
        }
    }
}
#endif
