import UIKit
import SwiftUI

/// Haptic feedback used across the app. Respects the user's "Vibrations" setting
/// (Profile → Notifications) on top of the system's own haptics switch.
enum Haptics {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "haptics.enabled") as? Bool ?? true }

    /// Light tap: tabs, chips, toggles, segmented controls.
    static func select() {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Button press weight.
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func error() { notify(.error) }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

extension Toast.Style {
    func playHaptic() {
        switch self {
        case .success: Haptics.success()
        case .error: Haptics.error()
        case .info: Haptics.tap(.soft)
        }
    }
}
