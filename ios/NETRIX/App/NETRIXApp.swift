import SwiftUI
import UIKit

@main
struct NETRIXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    init() {
        FontLoader.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.store)
                .environmentObject(UploadManager.shared)
                .preferredColorScheme(.dark)
                .tint(NX.ice)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The system relaunches the app in the background when film upload parts finish.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == AppConfig.uploadSessionID else { completionHandler(); return }
        UploadManager.shared.backgroundCompletionHandler = completionHandler
        UploadManager.shared.resumeIfNeeded()
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            switch app.phase {
            case .launching:
                SplashView().transition(.opacity)
            case .signedOut:
                AuthFlowView().transition(.opacity)
            case .setup:
                SetupFlowView().transition(.move(edge: .trailing).combined(with: .opacity))
            case .signedIn:
                MainTabView().transition(.opacity)
            }
        }
        .overlay(alignment: .top) { ToastHost() }
        .task { await app.bootstrap() }
    }
}

/// Shows `app.toast` as the design's banner, then dismisses it.
struct ToastHost: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        ZStack {
            if let toast = app.toast {
                BannerView(toast: toast)
                    .padding(.horizontal, NX.margin)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { app.toast = nil }
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if app.toast?.id == toast.id { withAnimation { app.toast = nil } }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: app.toast)
    }
}
