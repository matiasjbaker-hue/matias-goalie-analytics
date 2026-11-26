import SwiftUI

enum SetupOptions {
    static let ageGroups = ["U12", "U14", "U16", "U18", "Junior", "Adult"]
    static let levels = ["Recreational", "Rep / Travel", "AAA / Elite", "Junior A / B", "College", "Pro"]
    static let focus: [(String, String)] = [
        ("Positioning", "Depth, angles and net coverage"),
        ("Rebound control", "Direct and smother second chances"),
        ("Movement & technique", "Pushes, recoveries and post work"),
        ("Reading the play", "Anticipating passes and shooters"),
        ("Puck tracking", "Following the puck through traffic"),
    ]

    /// `level` holds "U18 · AAA / Elite"; split it back for editing.
    static func split(level: String?) -> (age: String?, comp: String?) {
        guard let level else { return (nil, nil) }
        let parts = level.components(separatedBy: " · ")
        let age = parts.first.flatMap { ageGroups.contains($0) ? $0 : nil }
        let comp = parts.last.flatMap { levels.contains($0) ? $0 : nil }
        return (age, comp)
    }
    static func join(age: String?, comp: String?) -> String? {
        let parts = [age, comp].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 02.15–02.18: athlete profile → team and level → goals. Saved to the same profile
/// columns the website uses (full_name, birth_year, catches, height_in, team, level).
struct SetupFlowView: View {
    @EnvironmentObject private var app: AppState
    @State private var step = 1
    @State private var first = ""
    @State private var last = ""
    @State private var dob = Calendar.current.date(byAdding: .year, value: -16, to: Date()) ?? Date()
    @State private var dobSet = false
    @State private var hand: String? = nil
    @State private var heightCm = ""
    @State private var team = ""
    @State private var age: String? = nil
    @State private var comp: String? = nil
    @AppStorage("focusAreas") private var focusStore = ""
    @State private var focus: [String] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepBars(total: 3, current: step).padding(.horizontal, NX.margin).padding(.top, NX.S.s)
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    Overline("Step \(step) of 3").padding(.top, NX.S.xl)
                    switch step {
                    case 1: athlete
                    case 2: teamLevel
                    default: goals
                    }
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error) }
                }
                .padding(.horizontal, NX.margin)
                .animation(.easeInOut, value: step)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: 4) {
                Button(step == 3 ? "Finish setup" : "Continue", action: next)
                    .buttonStyle(.nxPrimary(loading: saving))
                    .disabled(!canContinue || saving)
                if step > 1 {
                    Button("Back") { withAnimation { step -= 1 } }.buttonStyle(.nxTertiary).frame(height: 44)
                } else {
                    Button("Log out") { Task { await app.signOut() } }.buttonStyle(.nxTertiary).frame(height: 44)
                }
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
        .nxScreen()
        .onAppear(perform: prefill)
    }

    // MARK: Steps

    private var athlete: some View {
        VStack(alignment: .leading, spacing: NX.S.l) {
            Text("Your athlete profile").font(.nxH1).foregroundStyle(.white)
            Text("Tell us about you so your analysis is personalised.").font(.nxBody).foregroundStyle(NX.textSecondary)
            HStack(spacing: NX.S.m) {
                NXTextField(label: "First name", icon: "person", text: $first, isValid: !first.trimmed.isEmpty,
                            contentType: .givenName, autocapitalization: .words)
                NXTextField(label: "Last name", icon: "person", text: $last, isValid: !last.trimmed.isEmpty,
                            contentType: .familyName, autocapitalization: .words)
            }
            HStack(spacing: NX.S.m) {
                Image(systemName: "calendar").foregroundStyle(NX.textSecondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Date of birth").font(.nxCaption).foregroundStyle(NX.textMuted)
                    DatePicker("Date of birth", selection: $dob, in: ...Date(), displayedComponents: .date)
                        .labelsHidden().tint(NX.ice)
                        .onChange(of: dob) { _, _ in dobSet = true }
                }
                Spacer()
                if dobSet { Image(systemName: "checkmark.circle").foregroundStyle(NX.success) }
            }
            .padding(.horizontal, NX.S.l).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 20).fill(NX.field))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(NX.borderSubtle))
            Text("CATCHING HAND").font(.nxOverline).tracking(1.2).foregroundStyle(NX.textMuted).padding(.top, 4)
            HStack(spacing: 0) {
                handButton("Left", "L")
                handButton("Right", "R")
            }
            .padding(4)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().stroke(NX.borderSubtle))
            NXTextField(label: "Height in cm (optional)", icon: "arrow.up.and.down", text: $heightCm,
                        keyboard: .numberPad, submitLabel: .done)
        }
    }

    private func handButton(_ title: String, _ code: String) -> some View {
        Button { withAnimation(.spring(response: 0.3)) { hand = code } } label: {
            Label(title, systemImage: "hand.raised")
                .font(.sora(15, .semibold))
                .foregroundStyle(hand == code ? NX.navy : .white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(Capsule().fill(hand == code ? NX.cream : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(hand == code ? .isSelected : [])
    }

    private var teamLevel: some View {
        VStack(alignment: .leading, spacing: NX.S.l) {
            Text("Team and level").font(.nxH1).foregroundStyle(.white)
            Text("This sets the context for your reports.").font(.nxBody).foregroundStyle(NX.textSecondary)
            NXTextField(label: "Team", icon: "shield", text: $team, isValid: !team.trimmed.isEmpty, autocapitalization: .words)
            Text("AGE GROUP").font(.nxOverline).tracking(1.2).foregroundStyle(NX.textMuted).padding(.top, 4)
            FlowLayout {
                ForEach(SetupOptions.ageGroups, id: \.self) { a in ChoiceChip(title: a, selected: age == a) { age = a } }
            }
            Text("COMPETITION LEVEL").font(.nxOverline).tracking(1.2).foregroundStyle(NX.textMuted).padding(.top, 4)
            FlowLayout {
                ForEach(SetupOptions.levels, id: \.self) { l in ChoiceChip(title: l, selected: comp == l) { comp = l } }
            }
        }
    }

    private var goals: some View {
        VStack(alignment: .leading, spacing: NX.S.l) {
            Text("What do you want to improve?").font(.nxH1).foregroundStyle(.white)
            Text("Pick up to three. You can change these any time.").font(.nxBody).foregroundStyle(NX.textSecondary)
            HStack {
                Text("YOUR FOCUS").font(.nxOverline).tracking(1.2).foregroundStyle(NX.textMuted)
                Spacer()
                Text("\(focus.count) of 3").font(.nxCaption).foregroundStyle(NX.textMuted)
            }
            ForEach(Array(focus.enumerated()), id: \.element) { i, f in
                HStack(spacing: NX.S.m) {
                    Text("\(i + 1)").font(.sora(13, .bold)).foregroundStyle(NX.navy).frame(width: 26, height: 26).background(Circle().fill(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f).font(.sora(15, .semibold)).foregroundStyle(.white)
                        Text(SetupOptions.focus.first { $0.0 == f }?.1 ?? "").font(.nxCaption).foregroundStyle(NX.textMuted)
                    }
                    Spacer()
                    Button { focus.removeAll { $0 == f } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(NX.textMuted).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Remove \(f)")
                }
                .padding(.leading, NX.S.l).frame(minHeight: 64).nxCard(padding: 0, radius: 20)
            }
            if focus.count < 3 {
                HStack {
                    Text("\(focus.count + 1)").font(.sora(12)).foregroundStyle(NX.textMuted)
                        .frame(width: 24, height: 24).overlay(Circle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(NX.textMuted))
                    Text(focus.isEmpty ? "Pick a focus below" : "Add one more focus").font(.nxBody).foregroundStyle(NX.textMuted)
                    Text("Optional").font(.nxCaption).foregroundStyle(NX.textMuted.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, NX.S.l).frame(height: 56)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(NX.borderStrong))
            }
            Text("SUGGESTIONS").font(.nxOverline).tracking(1.2).foregroundStyle(NX.textMuted).padding(.top, 4)
            FlowLayout {
                ForEach(SetupOptions.focus.map(\.0).filter { !focus.contains($0) }, id: \.self) { f in
                    ChoiceChip(title: f, selected: false, icon: "plus") { if focus.count < 3 { focus.append(f) } }
                        .disabled(focus.count >= 3)
                }
            }
        }
    }

    // MARK: Logic

    private var canContinue: Bool {
        switch step {
        case 1: return !first.trimmed.isEmpty && !last.trimmed.isEmpty && hand != nil && (heightCm.isEmpty || heightCmValue != nil)
        case 2: return !team.trimmed.isEmpty
        default: return true
        }
    }

    private var heightCmValue: Int? {
        guard let v = Int(heightCm.trimmed), (92...244).contains(v) else { return nil }
        return v
    }

    private func prefill() {
        guard let me = app.me else { return }
        if first.isEmpty { first = me.firstName }
        if last.isEmpty { last = me.lastName }
        if let y = me.birthYear, let d = Calendar.current.date(from: DateComponents(year: y, month: 1, day: 1)) { dob = d; dobSet = true }
        hand = me.catches
        if let h = me.heightIn { heightCm = String(Int((Double(h) * 2.54).rounded())) }
        team = me.team ?? ""
        (age, comp) = SetupOptions.split(level: me.level)
        focus = focusStore.split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }

    private func next() {
        error = nil
        if step < 3 { withAnimation { step += 1 }; return }
        guard let me = app.me else { return }
        saving = true
        Task {
            do {
                var patch = ProfilePatch()
                patch.full_name = "\(first.trimmed) \(last.trimmed)"
                patch.catches = hand
                if dobSet { patch.birth_year = Calendar.current.component(.year, from: dob) }
                if let cm = heightCmValue { patch.height_in = Int((Double(cm) / 2.54).rounded()) }
                patch.team = team.trimmed
                patch.level = SetupOptions.join(age: age, comp: comp)
                let _: [Profile] = try await SupabaseClient.shared.update("profiles", query: "id=eq.\(me.id)", patch)
                focusStore = focus.joined(separator: "|")
                await app.profileUpdated()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
