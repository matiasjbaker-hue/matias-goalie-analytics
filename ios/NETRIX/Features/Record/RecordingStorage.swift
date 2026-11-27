import Foundation
import Photos
import SwiftUI

/// How much game film the phone has room for, and keeping a copy in Photos.
enum RecordingStorage {
    /// A full game is usually 75–90 minutes of recording (three periods with stoppages).
    static let fullGameMinutes = 90
    /// Space kept back so the phone (and the upload) still work.
    private static let reserveBytes: Int64 = 1_000_000_000

    static var freeBytes: Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Minutes of recording that fit, at the given quality.
    static func minutesLeft(mbPerMinute: Double, keepCopy: Bool = false) -> Int {
        let usable = max(0, freeBytes - reserveBytes)
        // Keeping a copy in Photos needs the film twice until the upload finishes.
        let perMinute = mbPerMinute * 1_048_576 * (keepCopy ? 2 : 1)
        return Int(Double(usable) / perMinute)
    }

    /// "1 h 40 min", kept on one line (non-breaking spaces).
    static func duration(_ minutes: Int) -> String {
        let s: String
        if minutes >= 60 { s = minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        else { s = "\(minutes) min" }
        return s.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static func size(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    /// Removes leftover empty recording folders (a film that wasn't uploaded is never touched).
    static func sweepEmptyFolders() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for d in dirs where ((try? FileManager.default.contentsOfDirectory(atPath: d.path))?.isEmpty ?? false) {
            try? FileManager.default.removeItem(at: d)
        }
    }

    /// Saves a copy of the film to the user's Photos (add-only access: NETRIX can't see their library).
    static func saveToPhotos(_ file: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw AppError(message: "NETRIX can't save to Photos. Allow it in Settings → NETRIX → Photos.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard freeBytes > size + 300_000_000 else {
            throw AppError(message: "Not enough space to keep a copy in Photos. The game will still upload.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file)
        }
    }
}

/// "Your iPhone can record about X" line, red when there isn't room for a full game.
struct StorageBanner: View {
    var mbPerMinute: Double = GameRecorder.Quality.hd60.mbPerMinute
    var qualityName: String = GameRecorder.Quality.hd60.rawValue
    var keepCopy = false
    var compact = false
    @State private var minutes = 0

    private var low: Bool { minutes < RecordingStorage.fullGameMinutes }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: low ? "exclamationmark.triangle.fill" : "internaldrive")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(low ? NX.warning : NX.ice)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.sora(13, .semibold)).foregroundStyle(.white)
                if low && !compact {
                    Text("A full game needs about \(RecordingStorage.duration(RecordingStorage.fullGameMinutes)) at \(qualityName)\(keepCopy ? " with a copy in Photos" : ""). Free up space in Settings → General → iPhone Storage before puck drop.")
                        .font(.sora(12)).foregroundStyle(NX.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(low ? NX.warning.opacity(0.14) : Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(low ? NX.warning.opacity(0.45) : NX.borderSubtle))
        .onAppear(perform: refresh)
        .onChange(of: mbPerMinute) { _, _ in refresh() }
        .onChange(of: keepCopy) { _, _ in refresh() }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if minutes <= 0 { return "Your iPhone is out of space for recording" }
        let d = RecordingStorage.duration(minutes)
        return low ? "Low storage: your iPhone can only record about \(d)" : "Your iPhone has room to record about \(d)"
    }

    private func refresh() {
        minutes = RecordingStorage.minutesLeft(mbPerMinute: mbPerMinute, keepCopy: keepCopy)
    }
}
