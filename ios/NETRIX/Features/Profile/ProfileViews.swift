import SwiftUI
import UserNotifications

// MARK: 07.09 Profile & settings

struct ProfileView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirmLogout = false

    var body: some View {
        ScrollView {
            VStack(spacing: NX.S.l) {
                VStack(spacing: NX.S.s) {
                    Text(app.me?.initials ?? "N").font(.sora(26, .semibold)).foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(LinearGradient(colors: [NX.royal, NX.navy], startPoint: .top, endPoint: .bottom)))
                        .overlay(Circle().stroke(NX.borderStrong))
                    Text(app.me?.fullName ?? "").font(.nxH2).foregroundStyle(.white)
                    Text(meta).font(.nxBodyS).foregroundStyle(NX.textMuted)
                }
                .padding(.top, NX.S.xxl)

                group("Account") {
                    NavigationLink(value: AppRoute.personalInfo) { ListRow(icon: "person", title: "Personal information") }
                    if app.me?.role != .coach {
                        NavigationLink(value: AppRoute.athleteInfo) { ListRow(icon: "figure.hockey", title: "Athlete information") }
                        NavigationLink(value: AppRoute.teamLevel) { ListRow(icon: "slider.horizontal.3", title: "Team & competition level") }
                    }
                }
                group("Preferences") {
                    NavigationLink(value: AppRoute.notifications) { ListRow(icon: "bell", title: "Notification preferences") }
                    NavigationLink(value: AppRoute.accountSettings) { ListRow(icon: "lock", title: "Account settings") }
                }
                group("Support") {
                    NavigationLink(value: AppRoute.help) { ListRow(icon: "questionmark.circle", title: "Help & support") }
                }
                Button("Log out") { confirmLogout = true }.buttonStyle(.nxDestructive).padding(.top, NX.S.s)
                Text("NETRIX \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .font(.nxCaption).foregroundStyle(NX.textMuted)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xxl)
        }
        .nxScreen()
        .confirmationDialog("Log out of NETRIX?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { Task { await app.signOut() } }
        }
    }

    private var meta: String {
        [app.me?.team, app.me?.level].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: NX.S.s) {
            Overline(title, color: NX.textMuted)
            content()
        }
    }
}

/// Common chrome for the settings detail screens: app bar, scrolling body, bottom "Save changes".
struct SettingsScreen<Content: View>: View {
    let title: String
    var saveTitle: String? = "Save changes"
    var canSave = true
    var saving = false
    var onSave: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AppBar(title: title, onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) { content() }
                    .padding(.horizontal, NX.margin).padding(.vertical, NX.S.s)
            }
            .scrollDismissesKeyboard(.interactively)
            if let saveTitle, let onSave {
                Button(saveTitle, action: onSave).buttonStyle(.nxPrimary(loading: saving)).disabled(!canSave || saving)
                    .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
            }
        }
        .nxScreen()
    }
}

private func sectionLabel(_ t: String) -> some View {
    Text(t.uppercased()).font(.nxOverline).tracking(1.2).foregroundStyle(NX.textMuted).padding(.top, 4)
}

@MainActor private func saveProfile(_ app: AppState, _ patch: ProfilePatch) async throws {
    guard let id = app.me?.id else { throw AppError.signedOut }
    let _: [Profile] = try await SupabaseClient.shared.update("profiles", query: "id=eq.\(id)", patch)
    await app.profileUpdated()
    if app.selectedGoalieId == id { await app.refreshStore() }
}

// MARK: 07.10 Personal information

struct PersonalInfoView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var last = ""
    @State private var birthYear = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SettingsScreen(title: "Personal information", canSave: !first.trimmed.isEmpty, saving: saving, onSave: save) {
            HStack(spacing: NX.S.m) {
                NXTextField(label: "First name", text: $first, contentType: .givenName, autocapitalization: .words)
                NXTextField(label: "Last name", text: $last, contentType: .familyName, autocapitalization: .words)
            }
            NXTextField(label: "Email", icon: "envelope", text: .constant(app.session?.user.email ?? ""),
                        helper: "Change it in Account settings.")
                .disabled(true)
            if app.me?.role != .coach {
                NXTextField(label: "Birth year", icon: "calendar", text: $birthYear, keyboard: .numberPad)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error) }
        }
        .onAppear {
            first = app.me?.firstName ?? ""; last = app.me?.lastName ?? ""
            birthYear = app.me?.birthYear.map(String.init) ?? ""
        }
    }

    private func save() {
        saving = true; error = nil
        Task {
            var p = ProfilePatch()
            p.full_name = [first.trimmed, last.trimmed].filter { !$0.isEmpty }.joined(separator: " ")
            if let y = Int(birthYear), (1940...Calendar.current.component(.year, from: Date())).contains(y) { p.birth_year = y }
            do { try await saveProfile(app, p); app.toast = Toast("Saved", style: .success); dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

// MARK: 07.11 Athlete information

struct AthleteInfoView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("focusAreas") private var focusStore = ""
    @State private var catches: String?
    @State private var heightCm = ""
    @State private var weightKg = ""
    @State private var focus: Set<String> = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SettingsScreen(title: "Athlete information", saving: saving, onSave: save) {
            sectionLabel("Catches")
            HStack { ForEach([("Left", "L"), ("Right", "R")], id: \.1) { t, c in ChoiceChip(title: t, selected: catches == c) { catches = c } } }
            NXTextField(label: "Height (cm)", icon: "arrow.up.and.down", text: $heightCm, keyboard: .numberPad)
            NXTextField(label: "Weight (kg)", icon: "scalemass", text: $weightKg, keyboard: .numberPad)
            sectionLabel("Development goals")
            FlowLayout {
                ForEach(SetupOptions.focus.map(\.0), id: \.self) { f in
                    ChoiceChip(title: f, selected: focus.contains(f)) { if focus.contains(f) { focus.remove(f) } else if focus.count < 3 { focus.insert(f) } }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error) }
        }
        .onAppear {
            catches = app.me?.catches
            heightCm = app.me?.heightIn.map { String(Int((Double($0) * 2.54).rounded())) } ?? ""
            weightKg = app.me?.weightLbs.map { String(Int((Double($0) / 2.2046).rounded())) } ?? ""
            focus = Set(focusStore.split(separator: "|").map(String.init))
        }
    }

    private func save() {
        saving = true; error = nil
        Task {
            var p = ProfilePatch()
            p.catches = catches
            if let cm = Int(heightCm), (92...244).contains(cm) { p.height_in = Int((Double(cm) / 2.54).rounded()) }
            if let kg = Int(weightKg), (18...180).contains(kg) { p.weight_lbs = Int((Double(kg) * 2.2046).rounded()) }
            do {
                try await saveProfile(app, p)
                focusStore = focus.sorted().joined(separator: "|")
                app.toast = Toast("Saved", style: .success); dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

// MARK: 07.12 Team & level

struct TeamLevelEditView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var team = ""
    @State private var age: String?
    @State private var comp: String?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SettingsScreen(title: "Team & level", canSave: !team.trimmed.isEmpty, saving: saving, onSave: save) {
            NXTextField(label: "Team", icon: "shield", text: $team, autocapitalization: .words)
            sectionLabel("Age group")
            FlowLayout { ForEach(SetupOptions.ageGroups, id: \.self) { a in ChoiceChip(title: a, selected: age == a) { age = a } } }
            sectionLabel("Competition level")
            FlowLayout { ForEach(SetupOptions.levels, id: \.self) { l in ChoiceChip(title: l, selected: comp == l) { comp = l } } }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error) }
        }
        .onAppear {
            team = app.me?.team ?? ""
            (age, comp) = SetupOptions.split(level: app.me?.level)
        }
    }

    private func save() {
        saving = true; error = nil
        Task {
            var p = ProfilePatch()
            p.team = team.trimmed
            p.level = SetupOptions.join(age: age, comp: comp)
            do { try await saveProfile(app, p); app.toast = Toast("Saved", style: .success); dismiss() }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

// MARK: 07.13 Notifications

struct NotificationsView: View {
    @AppStorage("notify.uploads") private var uploads = true
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        SettingsScreen(title: "Notifications", saveTitle: nil) {
            Text("Stay in the loop").font(.nxH1).foregroundStyle(.white)
            Text("Choose what NETRIX sends you.").font(.nxBodyS).foregroundStyle(NX.textMuted)
            toggle("Upload updates", "When your film finishes uploading, or needs a retry", $uploads)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report ready").font(.nxBody).foregroundStyle(.white)
                    Text("We email you when your analysis is published").font(.nxCaption).foregroundStyle(NX.textMuted)
                }
                Spacer()
                Text("By email").font(.nxCaption).foregroundStyle(NX.textMuted)
            }
            .nxCard(radius: NX.R.lg)
            if status == .denied {
                Button("Turn on notifications in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.nxSecondary)
            }
        }
        .task { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        .onChange(of: uploads) { _, on in
            if on { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } }
        }
    }

    private func toggle(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.nxBody).foregroundStyle(.white)
                Text(subtitle).font(.nxCaption).foregroundStyle(NX.textMuted)
            }
        }
        .tint(NX.royal)
        .nxCard(radius: NX.R.lg)
    }
}

// MARK: 07.14 Account settings (change email / password, delete account)

struct AccountSettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var sheet: Sheet?
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var error: String?

    enum Sheet: String, Identifiable { case email, password; var id: String { rawValue } }

    var body: some View {
        SettingsScreen(title: "Account settings", saveTitle: nil) {
            sectionLabel("Login")
            Button { sheet = .email } label: { ListRow(icon: "envelope", title: "Change email", subtitle: app.session?.user.email) }.buttonStyle(.plain)
            Button { sheet = .password } label: { ListRow(icon: "lock", title: "Change password") }.buttonStyle(.plain)
            sectionLabel("Danger zone")
            HStack(alignment: .top, spacing: NX.S.m) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(NX.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete account").font(.nxLabel).foregroundStyle(.white)
                    Text("This permanently removes your profile, games, film and reports. It can't be undone.")
                        .font(.nxCaption).foregroundStyle(NX.textSecondary)
                }
            }
            .nxCard(radius: NX.R.lg)
            Button("Delete my account") { confirmDelete = true }.buttonStyle(.nxDestructive(loading: deleting)).disabled(deleting)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error) }
        }
        .sheet(item: $sheet) { s in
            CredentialSheet(kind: s)
                .presentationDetents([.medium])
                .presentationBackground(Color(hex: 0x111318))
                .presentationCornerRadius(28)
        }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Delete permanently", role: .destructive, action: deleteAccount)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile, games, film and reports will be permanently deleted. This can't be undone.")
        }
    }

    private func deleteAccount() {
        guard let id = app.me?.id else { return }
        deleting = true; error = nil
        Task {
            do {
                try await APIClient.deleteAccount(userId: id)
                await app.accountDeleted()
            } catch { self.error = error.localizedDescription }
            deleting = false
        }
    }
}

private struct CredentialSheet: View {
    let kind: AccountSettingsView.Sheet
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var error: String?

    private var valid: Bool {
        kind == .email ? value.isPlausibleEmail
            : value.count >= 8 && value.rangeOfCharacter(from: .decimalDigits) != nil && value == confirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NX.S.l) {
            Text(kind == .email ? "Change email" : "Change password").font(.nxH2).foregroundStyle(.white)
            if kind == .email {
                NXTextField(label: "New email", icon: "envelope", text: $value, keyboard: .emailAddress,
                            contentType: .emailAddress, autocapitalization: .never)
                Text("We'll send a confirmation link to the new address. Your email changes once you tap it.")
                    .font(.nxCaption).foregroundStyle(NX.textMuted)
            } else {
                NXTextField(label: "New password", icon: "lock", text: $value, isSecure: true, contentType: .newPassword)
                StrengthMeter(password: value)
                NXTextField(label: "Confirm password", icon: "lock", text: $confirm, isSecure: true,
                            error: !confirm.isEmpty && confirm != value ? "Passwords don't match" : nil, contentType: .newPassword)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error) }
            Spacer()
            Button(kind == .email ? "Send confirmation" : "Update password", action: save)
                .buttonStyle(.nxPrimary(loading: saving)).disabled(!valid || saving)
        }
        .padding(NX.margin)
    }

    private func save() {
        saving = true; error = nil
        Task {
            do {
                if kind == .email { try await SupabaseClient.shared.updateUser(email: value.trimmed.lowercased()) }
                else { try await SupabaseClient.shared.updateUser(password: value) }
                app.toast = Toast(kind == .email ? "Check your new inbox" : "Password updated",
                                  message: kind == .email ? "Tap the link we sent to confirm the change." : nil, style: .success)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

// MARK: 07.15 Help & support

struct HelpView: View {
    @EnvironmentObject private var app: AppState
    @State private var open: String?
    @State private var showContact = false

    private let faqs: [(String, String, String)] = [
        ("clock", "How long does an analysis take?",
         "An analyst tags every shot in your game by hand, so it depends on the length of the film and the queue. You'll see the status move from Pending to In review, and your report appears in History as soon as it's approved."),
        ("video", "What video formats can I upload?",
         "MP4 and MOV files from your phone, camera or Files app. Full games are fine: the upload keeps going in the background, and resumes if your connection drops. You can also paste a link from your hockey video platform."),
        ("questionmark.circle", "Why is my report pending?",
         "Pending means your film arrived and is waiting for an analyst. If something is missing, the game shows Needs action with a note from the analyst."),
        ("chart.bar", "What do GSAx and high-danger mean?",
         "GSAx (goals saved above expected) compares the goals you allowed with the expected goals from the shots you faced. High-danger shots are the A+ and A graded chances, mostly from the slot and the crease."),
    ]

    var body: some View {
        SettingsScreen(title: "Help & support", saveTitle: "Contact support", onSave: { showContact = true }) {
            Text("How can we help?").font(.nxH1).foregroundStyle(.white)
            sectionLabel("Popular questions")
            ForEach(faqs, id: \.1) { icon, q, a in
                VStack(alignment: .leading, spacing: NX.S.s) {
                    Button { withAnimation(.easeInOut) { open = open == q ? nil : q } } label: {
                        HStack(spacing: NX.S.m) {
                            Image(systemName: icon).foregroundStyle(NX.textSecondary).frame(width: 24)
                            Text(q).font(.nxBody).foregroundStyle(.white).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(NX.textMuted)
                                .rotationEffect(.degrees(open == q ? 180 : 0))
                        }
                    }
                    .buttonStyle(.plain)
                    if open == q { Text(a).font(.nxBodyS).foregroundStyle(NX.textSecondary).padding(.leading, 36) }
                }
                .nxCard(radius: NX.R.lg)
            }
            HStack(spacing: NX.S.l) {
                Link("Terms", destination: AppConfig.termsURL)
                Link("Privacy", destination: AppConfig.privacyURL)
            }
            .font(.nxLabel).foregroundStyle(NX.ice).padding(.top, NX.S.s)
        }
        .sheet(isPresented: $showContact) {
            ContactSheet()
                .presentationDetents([.large])
                .presentationBackground(Color(hex: 0x111318))
                .presentationCornerRadius(28)
        }
    }
}

/// Sends a message to the NETRIX team (stored in the same `feedback` table the website uses).
private struct ContactSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var category = "other"
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NX.S.l) {
            Text("Contact support").font(.nxH2).foregroundStyle(.white)
            HStack {
                ChoiceChip(title: "Question", selected: category == "other") { category = "other" }
                ChoiceChip(title: "Bug", selected: category == "bug") { category = "bug" }
                ChoiceChip(title: "Idea", selected: category == "idea") { category = "idea" }
            }
            NXTextArea(placeholder: "How can we help?", text: $message, limit: 2000)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error) }
            Text("Or email \(AppConfig.supportEmail)").font(.nxCaption).foregroundStyle(NX.textMuted)
            Spacer()
            Button("Send", action: send).buttonStyle(.nxPrimary(loading: sending)).disabled(message.trimmed.count < 3 || sending)
        }
        .padding(NX.margin)
    }

    private func send() {
        guard let me = app.me else { return }
        sending = true; error = nil
        Task {
            struct Row: Encodable { let user_id: String; let role: String; let category: String; let message: String }
            do {
                try await SupabaseClient.shared.insertIgnoringResult("feedback",
                    Row(user_id: me.id, role: me.role.rawValue, category: category, message: "[iOS] " + message.trimmed))
                app.toast = Toast("Message sent", message: "We'll get back to you by email.", style: .success)
                dismiss()
            } catch { self.error = error.localizedDescription }
            sending = false
        }
    }
}
