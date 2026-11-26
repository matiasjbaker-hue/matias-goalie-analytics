import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A picked video, copied into a temporary file the app owns.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

/// Decides, before any upload starts, whether this account can submit a game.
/// Messages state the account status only; the app never points to purchasing.
enum SubmitGate {
    static func check(isCoach: Bool) async -> String? {
        if isCoach { return nil } // the database checks the coach's games on submit
        let db = SupabaseClient.shared
        if let data = try? await db.rpc("my_coach_cover", [String: String]()),
           let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any], !json.isEmpty {
            if let left = json["games_left"] as? Int, left <= 0 {
                return "Your coach's account has no games left right now, so this game can't be submitted yet."
            }
            return nil
        }
        guard let uid = await db.session?.user.id else { return AppError.signedOut.message }
        let rows: [GoalieAccess] = (try? await db.select("goalie_access", query: "user_id=eq.\(uid)&select=*")) ?? []
        if let access = rows.first {
            if !access.isActive { return "This account doesn't have active access to submit games right now." }
            if access.plan == "pay_per_game" && (access.gameCredits ?? 0) <= 0 {
                return "No game credits are left on this account, so this game can't be submitted right now."
            }
            return nil
        }
        // New account: the first game is free (same as the website's free first game).
        if let data = try? await db.rpc("my_free_game_blocked", [String: String]()),
           String(data: data, encoding: .utf8)?.trimmed == "true" {
            return nil // a coach covers this goalie; the database confirms on submit
        }
        do { _ = try await db.rpc("start_free_trial", [String: String]()); return nil }
        catch { return nil }
    }
}

struct SubmitFlowView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: GoalieStore
    @EnvironmentObject private var uploads: UploadManager
    @Environment(\.dismiss) private var dismiss

    enum Step: Int { case footage = 1, details, notes, review, done }
    @State private var step: Step = .footage

    // Footage
    @State private var photoItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var preparing = false
    @State private var footageError: String?
    @State private var link = ""
    @State private var useLink = false

    // Details
    @State private var date = Date()
    @State private var opponent = ""
    @State private var venue = "Home"
    @State private var teamGoals = ""
    @State private var oppGoals = ""
    @State private var jersey = ""
    @State private var shots = ""
    @State private var saves = ""
    @State private var minutes = ""

    // Notes
    @State private var notes = ""
    @State private var focus: Set<String> = []

    @State private var submitting = false
    @State private var submitError: String?
    @State private var confirmExit = false
    @State private var sentLink = false

    private var ownerId: String? { app.selectedGoalieId ?? app.me?.id }

    var body: some View {
        VStack(spacing: 0) {
            if step != .done {
                AppBar(title: step == .review ? "Review & submit" : "Submit a game", onBack: back)
                if step != .review {
                    StepBars(total: 3, current: step.rawValue).padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
                }
            }
            Group {
                switch step {
                case .footage: footageStep
                case .details: detailsStep
                case .notes: notesStep
                case .review: reviewStep
                case .done: SubmittedView(opponent: opponent, date: date, viaLink: sentLink, onTrack: { dismiss() }, onHome: { dismiss() })
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .nxScreen()
        .animation(.easeInOut(duration: 0.25), value: step)
        .confirmationDialog("Discard this submission?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { if uploads.isBusy && uploads.awaitingDetails { uploads.cancel() }; dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text(uploads.awaitingDetails ? "The film that's uploading will be removed. Nothing is used." : "Nothing has been submitted yet.")
        }
        .onChange(of: photoItem) { _, item in if let item { Task { await importPhoto(item) } } }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
        }
        .onAppear { uploads.clearFinished() }
    }

    private func back() {
        switch step {
        case .footage:
            if uploads.awaitingDetails || !opponent.isEmpty { confirmExit = true } else { dismiss() }
        case .details: step = .footage
        case .notes: step = .details
        case .review: step = .notes
        case .done: dismiss()
        }
    }

    // MARK: 04.01–04.03 Footage

    private var uploadState: (title: String, subtitle: String, icon: String, color: Color)? {
        guard let job = uploads.job, uploads.awaitingDetails || job.state == .failed else { return nil }
        switch job.state {
        case .failed: return ("Upload failed", job.errorMessage ?? "Connection lost. Tap to retry.", "exclamationmark.circle", NX.error)
        case .uploading where uploads.progress >= 1: return ("Upload complete", "Ready when you are", "checkmark", NX.success)
        default: return ("Uploading… \(Int(uploads.progress * 100))%", "Keeps going if you leave the app", "arrow.up", NX.ice)
        }
    }

    private var footageStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    Text("Add your game footage").font(.nxH1).foregroundStyle(.white).padding(.top, NX.S.l)
                    Text("Upload a video or paste a link from your hockey video platform.").font(.nxBody).foregroundStyle(NX.textSecondary)
                    dropzone
                    if let footageError {
                        Label(footageError, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error)
                    }
                    if uploads.job == nil && !preparing {
                        Text("or").font(.nxBodyS).foregroundStyle(NX.textMuted).frame(maxWidth: .infinity)
                        NXTextField(label: "Paste a video link", icon: "link", text: $link, keyboard: .URL,
                                    contentType: .URL, autocapitalization: .never, submitLabel: .done)
                        Text("Make sure the link is viewable by anyone with it.").font(.nxCaption).foregroundStyle(NX.textMuted)
                    }
                }
                .padding(.horizontal, NX.margin)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: 4) {
                Button("Continue") { useLink = uploads.job == nil; step = .details }
                    .buttonStyle(.nxPrimary)
                    .disabled(!(uploads.awaitingDetails && uploads.job?.state != .failed) && !linkValid)
                if uploads.awaitingDetails && uploads.job?.state == .uploading {
                    Button("Cancel upload") { uploads.cancel() }.buttonStyle(.nxTertiary).frame(height: 44)
                }
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
    }

    private var linkValid: Bool {
        guard let url = URL(string: link.trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }

    @ViewBuilder private var dropzone: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: NX.S.m) {
            if preparing {
                ProgressView().tint(NX.ice).scaleEffect(1.3).frame(height: 48)
                Text("Preparing video…").font(.sora(16, .semibold)).foregroundStyle(.white)
                Text("Large games can take a minute.").font(.nxCaption).foregroundStyle(NX.textMuted)
            } else if let state = uploadState {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 4)
                    Circle().trim(from: 0, to: uploads.progress).stroke(state.color, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    Image(systemName: state.icon).font(.system(size: 16, weight: .bold)).foregroundStyle(state.color)
                }
                .frame(width: 48, height: 48)
                Text(state.title).font(.sora(16, .semibold)).foregroundStyle(.white)
                Text(state.subtitle).font(.nxCaption).foregroundStyle(NX.textMuted)
                if uploads.job?.state == .failed {
                    HStack {
                        Button("Try again") { uploads.retry() }.buttonStyle(.nxTertiary)
                        Button("Remove") { uploads.cancel() }.buttonStyle(.nxTertiary)
                    }
                }
            } else {
                Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(NX.navy)
                    .frame(width: 44, height: 44).background(Circle().fill(NX.cream))
                Text("Upload game footage").font(.sora(16, .semibold)).foregroundStyle(.white)
                Text("MP4 or MOV, any length").font(.nxCaption).foregroundStyle(NX.textMuted)
                HStack(spacing: NX.S.s) {
                    PhotosPicker(selection: $photoItem, matching: .videos, preferredItemEncoding: .current) {
                        Label("Photos", systemImage: "photo.on.rectangle").font(.nxLabel)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    Button { showFiles = true } label: {
                        Label("Files", systemImage: "folder").font(.nxLabel)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).frame(minHeight: 200)
        .background(shape.fill(RadialGradient(colors: [NX.royal.opacity(0.22), Color.white.opacity(0.03)], center: .top, startRadius: 0, endRadius: 260)))
        .overlay(shape.stroke(uploadState?.color.opacity(0.5) ?? NX.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        footageError = nil
        preparing = true
        defer { preparing = false; photoItem = nil }
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                footageError = "That video couldn't be opened. Try another one, or use Files."; return
            }
            await startUpload(movie.url)
        } catch {
            footageError = "That video couldn't be opened. If it's in iCloud, wait for it to download and try again."
        }
    }

    private func importFile(_ url: URL) async {
        footageError = nil
        preparing = true
        defer { preparing = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
            await startUpload(tmp)
        } catch {
            footageError = "That file couldn't be read. Make sure it's fully downloaded, then try again."
        }
    }

    private func startUpload(_ file: URL) async {
        guard let ownerId else { return }
        if let blocked = await SubmitGate.check(isCoach: app.isCoach) {
            footageError = blocked
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try await uploads.start(file: file, ownerId: ownerId)
        } catch {
            footageError = error.localizedDescription
        }
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: 04.04 Game details

    private var detailsValid: Bool {
        !opponent.trimmed.isEmpty && Int(teamGoals) != nil && Int(oppGoals) != nil && !jersey.trimmed.isEmpty
    }

    private var detailsStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    Text("Game details").font(.nxH1).foregroundStyle(.white).padding(.top, NX.S.l)
                    HStack(spacing: NX.S.m) {
                        Image(systemName: "calendar").foregroundStyle(NX.textSecondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Game date").font(.nxCaption).foregroundStyle(NX.textMuted)
                            DatePicker("Game date", selection: $date, in: ...Date(), displayedComponents: .date).labelsHidden()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, NX.S.l).frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 20).fill(NX.field))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(NX.borderSubtle))
                    NXTextField(label: "Opponent", icon: "shield", text: $opponent, autocapitalization: .words)
                    label("Venue")
                    HStack { ForEach(["Home", "Away", "Neutral"], id: \.self) { v in ChoiceChip(title: v, selected: venue == v) { venue = v } } }
                    label("Final score")
                    HStack(spacing: NX.S.m) {
                        NXTextField(label: "Your team", text: $teamGoals, keyboard: .numberPad)
                        NXTextField(label: "Opponent", text: $oppGoals, keyboard: .numberPad)
                    }
                    NXTextField(label: "Your team's jersey colour", icon: "tshirt", text: $jersey,
                                helper: "So the analyst can find you in the film.", autocapitalization: .words)
                    label("Game statistics · optional")
                    HStack(spacing: NX.S.m) {
                        NXTextField(label: "Shots faced", text: $shots, keyboard: .numberPad)
                        NXTextField(label: "Saves", text: $saves, keyboard: .numberPad)
                    }
                    NXTextField(label: "Minutes played", text: $minutes, keyboard: .numberPad)
                }
                .padding(.horizontal, NX.margin)
            }
            .scrollDismissesKeyboard(.interactively)
            Button("Continue") { step = .notes }
                .buttonStyle(.nxPrimary).disabled(!detailsValid)
                .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.nxOverline).tracking(1.2).foregroundStyle(NX.textMuted).padding(.top, 4)
    }

    // MARK: 04.05 Notes

    private var notesStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    Text("Notes for the analyst").font(.nxH1).foregroundStyle(.white).padding(.top, NX.S.l)
                    Text("Tell us what to look for. Optional, but it helps.").font(.nxBody).foregroundStyle(NX.textSecondary)
                    label("Notes")
                    NXTextArea(placeholder: "e.g. I felt slow on cross-ice passes in the second period.", text: $notes)
                    label("Focus areas")
                    FlowLayout {
                        ForEach(["Positioning", "Rebound control", "Puck tracking", "Movement", "Technique"], id: \.self) { f in
                            ChoiceChip(title: f, selected: focus.contains(f)) {
                                if focus.contains(f) { focus.remove(f) } else { focus.insert(f) }
                            }
                        }
                    }
                }
                .padding(.horizontal, NX.margin)
            }
            .scrollDismissesKeyboard(.interactively)
            Button("Review & submit") { step = .review }
                .buttonStyle(.nxPrimary)
                .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
    }

    // MARK: 04.06 Review & submit (no prices or payment in the app)

    private var reviewStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    Text("Review and submit").font(.nxH1).foregroundStyle(.white).padding(.top, NX.S.s)
                    HStack(spacing: NX.S.m) {
                        FilmThumb(size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("vs \(opponent.trimmed)").font(.sora(17, .semibold)).foregroundStyle(.white)
                            Text("\(Fmt.shortDate.string(from: date)) · \(venue) · \(teamGoals)–\(oppGoals)").font(.nxCaption).foregroundStyle(NX.textMuted)
                            StatusChip(status: .pending)
                        }
                        Spacer()
                    }
                    .nxCard(radius: 20)
                    label("Footage")
                    HStack {
                        Image(systemName: useLink ? "link" : "film").foregroundStyle(NX.ice)
                        Text(useLink ? link.trimmed : footageSummary).font(.nxBody).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                    }
                    .nxCard(radius: NX.R.lg)
                    if !notes.trimmed.isEmpty || !focus.isEmpty {
                        label("For the analyst")
                        VStack(alignment: .leading, spacing: 8) {
                            if !focus.isEmpty { Text(focus.sorted().joined(separator: " · ")).font(.nxLabel).foregroundStyle(NX.ice) }
                            if !notes.trimmed.isEmpty { Text(notes.trimmed).font(.nxBody).foregroundStyle(NX.textSecondary) }
                        }
                        .nxCard(radius: NX.R.lg)
                    }
                    if let submitError {
                        BannerView(toast: Toast("Couldn't submit", message: submitError, style: .error))
                    }
                }
                .padding(.horizontal, NX.margin)
            }
            VStack(spacing: 4) {
                Button("Submit game", action: submit).buttonStyle(.nxPrimary(loading: submitting)).disabled(submitting)
                Button("Edit details") { step = .details }.buttonStyle(.nxTertiary).frame(height: 44)
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
    }

    private var footageSummary: String {
        guard let job = uploads.job else { return "Game film" }
        let gb = Double(job.fileSize) / 1_073_741_824
        let size = gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(job.fileSize) / 1_048_576)
        return "Game film · \(size)"
    }

    private var requested: RequestedGame {
        RequestedGame(date: Fmt.isoDay.string(from: date), opponent: opponent.trimmed, home_away: venue,
                      team_goals: Int(teamGoals), opponent_goals: Int(oppGoals),
                      season: app.selectedGoalie?.season ?? store.profile?.season,
                      goalie_note: notes.trimmed.isEmpty ? nil : notes.trimmed,
                      focus_areas: focus.isEmpty ? nil : focus.sorted(),
                      shots_faced: Int(shots), saves: Int(saves), minutes_played: Int(minutes))
    }

    private func submit() {
        submitError = nil
        submitting = true
        Task {
            defer { submitting = false }
            if useLink {
                do {
                    let g = "\(Fmt.isoDay.string(from: date)) vs \(opponent.trimmed) (\(venue)), final \(teamGoals)-\(oppGoals)"
                    var note = notes.trimmed
                    if !focus.isEmpty { note = "Focus: \(focus.sorted().joined(separator: ", "))\n" + note }
                    try await APIClient.sendFilmLink(url: link.trimmed, note: note, game: g, jerseyColor: jersey.trimmed)
                    sentLink = true
                    step = .done
                } catch { submitError = error.localizedDescription }
            } else {
                uploads.attach(requested: requested, jerseyColor: jersey.trimmed)
                step = .done
            }
        }
    }
}

// MARK: 04.07 Submission confirmed

struct SubmittedView: View {
    let opponent: String
    let date: Date
    let viaLink: Bool
    let onTrack: () -> Void
    let onHome: () -> Void
    @EnvironmentObject private var uploads: UploadManager

    private var uploading: Bool { !viaLink && uploads.job.map { $0.state == .uploading || $0.state == .finishing } == true }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: NX.S.l) {
                    HaloIcon(systemName: "checkmark", badge: false, tint: NX.success).padding(.top, NX.S.l)
                    Text(viaLink ? "Link sent" : "Game submitted").font(.nxH1).foregroundStyle(.white)
                    Text(viaLink ? "We'll pull your film from the link and start the analysis. It shows in History once it's in."
                                 : "An analyst will review it shortly. We will let you know when your report is ready.")
                        .font(.nxBody).foregroundStyle(NX.textSecondary).multilineTextAlignment(.center).padding(.horizontal, NX.S.l)
                    HStack(spacing: NX.S.m) {
                        FilmThumb(size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("vs \(opponent)").font(.sora(16, .semibold)).foregroundStyle(.white)
                            Text(Fmt.shortDate.string(from: date)).font(.nxCaption).foregroundStyle(NX.textMuted)
                            if uploading {
                                Text("Uploading… \(Int(uploads.progress * 100))%").font(.sora(12, .medium)).foregroundStyle(NX.ice)
                            } else {
                                StatusChip(status: .pending)
                            }
                        }
                        Spacer()
                    }
                    .nxCard(radius: 20)
                    VStack(alignment: .leading, spacing: NX.S.m) {
                        Overline("What happens next", color: NX.textMuted)
                        StepLine(title: viaLink ? "Link received" : (uploading ? "Uploading footage" : "Footage received"),
                                 subtitle: uploading ? "Keeps going if you close the app" : "Just now",
                                 state: uploading ? .active : .done)
                        StepLine(title: "Analyst review", subtitle: "An analyst tags every shot", state: uploading ? .todo : .active)
                        StepLine(title: "Report ready", subtitle: "Your stats appear in History", state: .todo)
                    }
                    .nxCard(radius: 20)
                }
                .padding(.horizontal, NX.margin)
            }
            VStack(spacing: 4) {
                Button("Track analysis", action: onTrack).buttonStyle(.nxPrimary)
                Button("Back to home", action: onHome).buttonStyle(.nxTertiary).frame(height: 44)
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
    }
}

struct StepLine: View {
    enum State { case done, active, todo }
    let title: String
    let subtitle: String
    let state: State
    var body: some View {
        HStack(alignment: .top, spacing: NX.S.m) {
            ZStack {
                switch state {
                case .done: Circle().fill(NX.success); Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(NX.navy)
                case .active: Circle().stroke(NX.ice, lineWidth: 2); Circle().fill(NX.ice).frame(width: 8, height: 8)
                case .todo: Circle().stroke(NX.borderStrong, lineWidth: 1.5)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.sora(15, .semibold)).foregroundStyle(state == .todo ? NX.textMuted : .white)
                Text(subtitle).font(.nxCaption).foregroundStyle(NX.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
