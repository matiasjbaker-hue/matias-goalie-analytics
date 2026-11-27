import SwiftUI
import UIKit
import UserNotifications

@main
struct NETRIXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

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
                .onOpenURL { url in app.handle(url: url) }
                .onReceive(NotificationCenter.default.publisher(for: .openRoute)) { note in
                    if let route = note.object as? String { app.pendingRoute = route }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        AppLock.shared.didBecomeActive()
                        if app.phase == .signedIn { Task { await app.refreshStore() } }
                    case .background:
                        AppLock.shared.didBackground()
                        ReportWatcher.schedule()
                    default: break
                    }
                }
        }
    }
}

extension Notification.Name {
    static let openRoute = Notification.Name("netrix.openRoute")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ReportWatcher.register()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let route = response.notification.request.content.userInfo["route"] as? String {
            await MainActor.run { NotificationCenter.default.post(name: .openRoute, object: route) }
        }
    }

    /// Portrait everywhere except the game recorder, which switches to landscape.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

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
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        ZStack {
            #if DEBUG
            if AppState.debugScreen == "widgets" { DebugWidgetGallery() }
            else if AppState.debugScreen == "crop" { AvatarCropView(image: AppState.debugPhoto) { _ in } }
            else if AppState.debugScreen == "recguide" { RecordingGuideView(onDone: {}) }
            else if AppState.debugScreen == "recorder" { GameRecorderView(onFinished: { _, _ in }, onCancel: {}) }
            else { phaseView }
            #else
            phaseView
            #endif
        }
        .overlay {
            if lock.locked && app.phase == .signedIn { LockScreen(lock: lock).transition(.opacity) }
        }
        .overlay(alignment: .top) { ToastHost() }
        .task {
            lock.appLaunched()
            await app.bootstrap()
            if let r = LaunchRoute.pending { app.pendingRoute = r; LaunchRoute.pending = nil }
        }
    }

    @ViewBuilder private var phaseView: some View {
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
                        toast.style.playHaptic()
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if app.toast?.id == toast.id { withAnimation { app.toast = nil } }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: app.toast)
    }
}
