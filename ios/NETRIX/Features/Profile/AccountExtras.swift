import SwiftUI

/// Game credits status for a goalie. States the balance only; the app never offers to buy.
struct CreditsCard: View {
    @EnvironmentObject private var app: AppState
    @State private var line: (title: String, detail: String)?

    var body: some View {
        Group {
            if let line {
                HStack(spacing: NX.S.m) {
                    Image(systemName: "ticket").font(.system(size: 15, weight: .semibold)).foregroundStyle(NX.ice)
                        .frame(width: 36, height: 36).background(Circle().fill(NX.ice.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.nxLabel).foregroundStyle(.white)
                        Text(line.detail).font(.nxCaption).foregroundStyle(NX.textMuted)
                    }
                    Spacer()
                }
                .nxCard(padding: 14, radius: NX.R.lg)
            }
        }
        .task { line = await Self.status(isCoach: app.isCoach) }
    }

    static func status(isCoach: Bool) async -> (String, String)? {
        let db = SupabaseClient.shared
        guard let uid = await db.session?.user.id else { return nil }
        if !isCoach,
           let data = try? await db.rpc("my_coach_cover", [String: String]()),
           let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any], !json.isEmpty {
            let coach = json["coach_name"] as? String ?? "Your coach"
            return ("Games covered by \(coach)", "Submitting a game uses your coach's account.")
        }
        let rows: [GoalieAccess] = (try? await db.select("goalie_access", query: "user_id=eq.\(uid)&select=*")) ?? []
        guard let a = rows.first else {
            return isCoach ? nil : ("Your first game is free", "Submit a game to get your first analysis.")
        }
        guard a.isActive else { return ("No active access", "This account can't submit games right now.") }
        if a.plan == "pay_per_game" {
            let n = a.gameCredits ?? 0
            return ("\(n) game credit\(n == 1 ? "" : "s") left", n > 0 ? "Each submitted game uses one credit." : "This account has no credits left right now.")
        }
        return ("Account active", a.accessUntil.map { "Access until \(Fmt.longDate.string(from: $0))" } ?? "You can submit games.")
    }
}

/// Coaches write notes for the selected goalie (same `coach_notes` table the website uses).
struct CoachNoteComposer: View {
    var gameId: String? = nil
    @EnvironmentObject private var app: AppState
    @State private var text = ""
    @State private var saving = false
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: NX.S.m) {
            if open {
                Overline("Note for \(app.selectedGoalie?.firstName ?? "your goalie")")
                NXTextArea(placeholder: gameId == nil ? "What should they work on this week?" : "Feedback on this game…", text: $text, limit: 1000)
                HStack {
                    Button("Cancel") { open = false; text = "" }.buttonStyle(.nxTertiary)
                    Spacer()
                    Button("Save note", action: save).buttonStyle(.nxPrimary(loading: saving))
                        .frame(width: 150).disabled(text.trimmed.count < 2 || saving)
                }
            } else {
                Button { open = true } label: { Label("Add a coach note", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(.nxSecondary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: open)
    }

    private func save() {
        guard let me = app.me, let goalie = app.selectedGoalieId, goalie != me.id else { return }
        saving = true
        Task {
            struct Row: Encodable { let coach_id: String; let goalie_id: String; let text: String; let game_id: Int? }
            do {
                try await SupabaseClient.shared.insertIgnoringResult("coach_notes",
                    Row(coach_id: me.id, goalie_id: goalie, text: text.trimmed, game_id: gameId.flatMap(Int.init)))
                text = ""; open = false
                app.toast = Toast("Note saved", message: "\(app.selectedGoalie?.firstName ?? "Your goalie") can see it now.", style: .success)
                await app.refreshStore()
            } catch {
                app.toast = Toast("Couldn't save the note", message: error.localizedDescription, style: .error)
            }
            saving = false
        }
    }
}

/// Coach home: assigned goalies at a glance; tap to switch whose data the app shows.
struct CoachRoster: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        if app.isCoach {
            VStack(alignment: .leading, spacing: NX.S.m) {
                SectionHeader(title: "Your goalies")
                if app.coachGoalies.isEmpty {
                    Text("No goalies are assigned to you yet. They appear here once they're linked to your account.")
                        .font(.nxBodyS).foregroundStyle(NX.textMuted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NX.S.s) {
                            ForEach(app.coachGoalies) { g in
                                let selected = g.id == app.selectedGoalieId
                                Button { Haptics.select(); app.selectedGoalieId = g.id } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        AvatarView(profile: g, size: 36, style: selected ? .light : .brand)
                                        Text(g.fullName ?? "Goalie").font(.nxLabel).foregroundStyle(.white).lineLimit(1)
                                        Text([g.team, g.level].compactMap { $0 }.joined(separator: " · ")).font(.nxCaption)
                                            .foregroundStyle(NX.textMuted).lineLimit(1)
                                    }
                                    .frame(width: 150, alignment: .leading)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 18).fill(selected ? NX.royal.opacity(0.35) : Color.white.opacity(0.045)))
                                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? NX.ice.opacity(0.6) : NX.borderSubtle))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                    }
                    if app.selectedGoalieId != app.me?.id { CoachNoteComposer() }
                }
            }
        }
    }
}
