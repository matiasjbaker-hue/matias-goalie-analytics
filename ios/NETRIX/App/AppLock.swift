import SwiftUI
import LocalAuthentication

/// Optional Face ID / Touch ID lock (Account settings → "Require Face ID").
/// Locks when the app goes to the background and asks again on return.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @AppStorage("lock.biometric") var enabled = false
    @Published private(set) var locked = false
    private var backgroundedAt: Date?

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType { case .faceID: return "Face ID"; case .touchID: return "Touch ID"; case .opticID: return "Optic ID"; default: return "Passcode" }
    }

    var isAvailable: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    func appLaunched() { if enabled { locked = true } }
    func didBackground() { backgroundedAt = Date() }
    func didBecomeActive() {
        // A short trip out (e.g. the photo picker or a share sheet) doesn't relock.
        if enabled, let t = backgroundedAt, Date().timeIntervalSince(t) > 30 { locked = true }
        backgroundedAt = nil
    }

    func unlock() async {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        do {
            if try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock NETRIX") {
                withAnimation { locked = false }
                Haptics.success()
            }
        } catch { Haptics.warning() }
    }

    /// Turning the lock on asks once, so nobody locks themselves out by accident.
    func setEnabled(_ on: Bool) async -> Bool {
        guard on else { enabled = false; return true }
        let ctx = LAContext()
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on \(biometryName) for NETRIX")) ?? false
        enabled = ok
        return ok
    }
}

struct LockScreen: View {
    @ObservedObject var lock: AppLock
    var body: some View {
        VStack(spacing: NX.S.xl) {
            Spacer()
            NetrixLockup(height: 24)
            Text("NETRIX is locked").font(.nxH2).foregroundStyle(.white)
            Spacer()
            Button { Task { await lock.unlock() } } label: {
                Label("Unlock with \(lock.biometryName)", systemImage: lock.biometryName == "Touch ID" ? "touchid" : "faceid")
            }
            .buttonStyle(.nxPrimary)
            .padding(.horizontal, NX.margin).padding(.bottom, NX.S.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NXBackground())
        .task { await lock.unlock() }
    }
}
