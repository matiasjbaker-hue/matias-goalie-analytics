import Foundation
import ActivityKit

/// Lock screen / Dynamic Island progress for a film upload.
enum UploadActivity {
    private static var current: Activity<FilmUploadAttributes>? {
        Activity<FilmUploadAttributes>.activities.first
    }
    private static var lastSent: Double = -1

    static func start(opponent: String, fileSize: Int64, progress: Double) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, current == nil else { return }
        let gb = Double(fileSize) / 1_073_741_824
        let size = gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(fileSize) / 1_048_576)
        let attrs = FilmUploadAttributes(opponent: opponent, fileSize: size)
        let state = FilmUploadAttributes.ContentState(progress: progress, phase: "uploading")
        _ = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil))
        lastSent = progress
    }

    /// Throttled to every 2% so the system budget isn't spent on tiny steps.
    static func update(progress: Double, phase: String) {
        guard let activity = current else { return }
        guard phase != "uploading" || abs(progress - lastSent) >= 0.02 else { return }
        lastSent = progress
        let state = FilmUploadAttributes.ContentState(progress: progress, phase: phase)
        Task { await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(3600))) }
    }

    static func end(phase: String) {
        guard let activity = current else { return }
        let state = FilmUploadAttributes.ContentState(progress: phase == "done" ? 1 : lastSent, phase: phase)
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(phase == "done" ? 60 * 15 : 60 * 60))) }
        lastSent = -1
    }
}
