import SwiftUI

enum AuthRoute: Hashable { case login, signUp, forgot, inbox(String) }

struct AuthFlowView: View {
    @AppStorage("seenIntro") private var seenIntro = false
    @State private var path = NavigationPath()

    var body: some View {
        if !seenIntro {
            IntroView(onFinish: { withAnimation { seenIntro = true } },
                      onLogin: { seenIntro = true; path.append(AuthRoute.login) })
                .transition(.opacity)
        } else {
            NavigationStack(path: $path) {
                WelcomeView(onLogin: { path.append(AuthRoute.login) }, onCreate: { path.append(AuthRoute.signUp) })
                    .navigationDestination(for: AuthRoute.self) { route in
                        switch route {
                        case .login: LoginView(path: $path)
                        case .signUp: SignUpView(path: $path)
                        case .forgot: ForgotPasswordView(path: $path)
                        case .inbox(let email): CheckInboxView(email: email, path: $path)
                        }
                    }
            }
            #if DEBUG
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if AppState.debugScreen == "login", path.isEmpty { path.append(AuthRoute.login) }
                if AppState.debugScreen == "signup", path.isEmpty { path.append(AuthRoute.signUp) }
            }
            #endif
        }
    }
}

/// Shared header: back button, overline, title, subtitle.
struct AuthHeader: View {
    let overline: String
    let title: String
    let subtitle: String
    var onBack: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onBack { CircleIconButton(systemName: "arrow.left", action: onBack).accessibilityLabel("Back").padding(.bottom, NX.S.xxl) }
            Overline(overline).padding(.bottom, NX.S.s)
            Text(title).font(.nxH1).foregroundStyle(.white)
            Text(subtitle).font(.nxBody).foregroundStyle(NX.textSecondary).padding(.top, NX.S.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 02.09 / 02.10 Log in

struct LoginView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var app: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    AuthHeader(overline: "Sign in", title: "Welcome back", subtitle: "Log in to see your latest analysis.",
                               onBack: { path.removeLast() })
                        .padding(.bottom, NX.S.s)
                    NXTextField(label: "Email", icon: "envelope", text: $email, keyboard: .emailAddress,
                                contentType: .username, autocapitalization: .never)
                    NXTextField(label: "Password", icon: "lock", text: $password, isSecure: true, error: error,
                                contentType: .password, submitLabel: .go, onSubmit: submit)
                    HStack {
                        Spacer()
                        Button("Forgot password?") { path.append(AuthRoute.forgot) }
                            .font(.nxLabel).foregroundStyle(NX.ice).frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, NX.margin).padding(.top, NX.S.s)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: NX.S.s) {
                Button("Log in", action: submit)
                    .buttonStyle(.nxPrimary(loading: loading))
                    .disabled(!email.isPlausibleEmail || password.isEmpty || loading)
                InlinePrompt(text: "New to NETRIX?", action: "Create account") { path.append(AuthRoute.signUp) }
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
        .nxScreen()
        .onChange(of: password) { _, _ in error = nil }
    }

    private func submit() {
        guard email.isPlausibleEmail, !password.isEmpty, !loading else { return }
        loading = true; error = nil
        Task {
            do {
                let s = try await SupabaseClient.shared.signIn(email: email.trimmed.lowercased(), password: password)
                Haptics.success()
                await app.signedIn(s)
            } catch {
                Haptics.error()
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: 02.06–02.08 Sign up

struct SignUpView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var app: AppState
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var agreed = false
    @State private var ageConfirmed = false
    @State private var loading = false
    @State private var error: String?
    @State private var confirmSent = false

    private var passwordOK: Bool { password.count >= 8 && password.rangeOfCharacter(from: .decimalDigits) != nil }
    private var canSubmit: Bool { name.trimmed.count >= 2 && email.isPlausibleEmail && passwordOK && agreed && ageConfirmed && !loading }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NX.S.l) {
                    AuthHeader(overline: "New account", title: "Create your account",
                               subtitle: "Start with your details. You can add athlete info next.",
                               onBack: { path.removeLast() })
                        .padding(.bottom, NX.S.s)
                    NXTextField(label: "Full name", icon: "person", text: $name, isValid: name.trimmed.count >= 2,
                                contentType: .name, autocapitalization: .words)
                    NXTextField(label: "Email", icon: "envelope", text: $email, isValid: email.isPlausibleEmail,
                                keyboard: .emailAddress, contentType: .username, autocapitalization: .never)
                    VStack(alignment: .leading, spacing: 10) {
                        NXTextField(label: "Password", icon: "lock", text: $password, isSecure: true,
                                    helper: password.isEmpty ? "At least 8 characters, including a number" : nil,
                                    contentType: .newPassword, submitLabel: .done)
                        StrengthMeter(password: password)
                    }
                    NXCheckbox(isOn: $agreed) {
                        HStack(spacing: 4) {
                            Text("I agree to the").foregroundStyle(NX.textSecondary)
                            Link("Terms", destination: AppConfig.termsURL).foregroundStyle(NX.ice)
                            Text("and").foregroundStyle(NX.textSecondary)
                            Link("Privacy Policy", destination: AppConfig.privacyURL).foregroundStyle(NX.ice)
                        }
                        .font(.nxBodyS)
                    }
                    // Same consent the website asks for at sign-up.
                    NXCheckbox(isOn: $ageConfirmed) {
                        Text("I'm 18 or older, or my parent or guardian has agreed to these terms for me.")
                            .font(.nxBodyS).foregroundStyle(NX.textSecondary)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.nxBodyS).foregroundStyle(NX.error)
                    }
                    if confirmSent {
                        BannerView(toast: Toast("Check your email", message: "Tap the link we sent to \(email.trimmed) to confirm your account, then log in.", style: .info))
                    }
                }
                .padding(.horizontal, NX.margin).padding(.top, NX.S.s)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: NX.S.s) {
                Button("Create account", action: submit)
                    .buttonStyle(.nxPrimary(loading: loading))
                    .disabled(!canSubmit)
                InlinePrompt(text: "Already have an account?", action: "Log in") {
                    path.removeLast(); path.append(AuthRoute.login)
                }
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
        .nxScreen()
    }

    private func submit() {
        guard canSubmit else { return }
        loading = true; error = nil
        Task {
            do {
                // Same consent record the website keeps with the account (auth user metadata).
                let meta: [String: AnyEncodable] = [
                    "name": AnyEncodable(name.trimmed),
                    "terms_accepted_at": AnyEncodable(ISO8601DateFormatter().string(from: Date())),
                    "terms_version": AnyEncodable("2026-10"),
                    "age_or_guardian_confirmed": AnyEncodable(ageConfirmed),
                    "heard_from": AnyEncodable("iOS app"),
                ]
                if let s = try await SupabaseClient.shared.signUp(email: email.trimmed.lowercased(), password: password, metadata: meta) {
                    await app.signedIn(s)
                } else {
                    confirmSent = true
                }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: 02.11 Forgot password

struct ForgotPasswordView: View {
    @Binding var path: NavigationPath
    @State private var email = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: NX.S.xxl) {
                AuthHeader(overline: "Account recovery", title: "Forgot password?",
                           subtitle: "Enter the email linked to your account and we will send you a reset link.",
                           onBack: { path.removeLast() })
                NXTextField(label: "Email", icon: "envelope", text: $email, error: error, keyboard: .emailAddress,
                            contentType: .username, autocapitalization: .never, submitLabel: .send, onSubmit: submit)
            }
            .padding(.horizontal, NX.margin).padding(.top, NX.S.s)
            Spacer()
            VStack(spacing: NX.S.s) {
                Button("Send reset link", action: submit)
                    .buttonStyle(.nxPrimary(loading: loading))
                    .disabled(!email.isPlausibleEmail || loading)
                InlinePrompt(text: "Remembered it?", action: "Back to log in") { path.removeLast() }
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
        .nxScreen()
    }

    private func submit() {
        guard email.isPlausibleEmail else { return }
        loading = true; error = nil
        Task {
            do {
                try await SupabaseClient.shared.sendPasswordReset(email: email.trimmed.lowercased())
                path.append(AuthRoute.inbox(email.trimmed.lowercased()))
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

// MARK: 02.12 Check your inbox

struct CheckInboxView: View {
    let email: String
    @Binding var path: NavigationPath
    @State private var cooldown = 45
    @State private var sending = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack { CircleIconButton(systemName: "arrow.left") { path.removeLast() }.accessibilityLabel("Back"); Spacer() }
                .padding(.horizontal, NX.margin)
            Spacer()
            HaloIcon(systemName: "envelope")
            VStack(spacing: NX.S.s) {
                Overline("Account recovery")
                Text("Check your inbox").font(.nxH1).foregroundStyle(.white)
                Text("We sent a secure reset link to").font(.nxBody).foregroundStyle(NX.textSecondary)
                Text(email).font(.nxLabel).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                Text("Open the link to choose a new password, then come back and log in.")
                    .font(.nxCaption).foregroundStyle(NX.textMuted).multilineTextAlignment(.center).padding(.top, 4)
            }
            .padding(.horizontal, NX.margin)
            Spacer()
            VStack(spacing: NX.S.m) {
                Button("Open email app") {
                    if let url = URL(string: "message://") { UIApplication.shared.open(url) }
                }
                .buttonStyle(.nxPrimary)
                Button("Back to log in") { path = NavigationPath(); path.append(AuthRoute.login) }
                    .buttonStyle(.nxSecondary)
                Button(action: resend) {
                    (Text("Didn't get it? ").foregroundColor(NX.textMuted)
                     + Text(cooldown > 0 ? "Resend in 0:\(String(format: "%02d", cooldown))" : "Resend").foregroundColor(NX.ice).bold())
                        .font(.nxBodyS)
                }
                .disabled(cooldown > 0 || sending)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.s)
        }
        .nxScreen()
        .onReceive(timer) { _ in if cooldown > 0 { cooldown -= 1 } }
    }

    private func resend() {
        sending = true
        Task {
            try? await SupabaseClient.shared.sendPasswordReset(email: email)
            cooldown = 45
            sending = false
        }
    }
}
