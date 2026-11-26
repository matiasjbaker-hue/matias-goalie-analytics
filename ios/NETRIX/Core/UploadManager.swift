import Foundation
import UIKit
import UserNotifications

/// Uploads game film straight to storage in 25 MB parts on a background URLSession,
/// so a 1-3 hour game keeps uploading when the app is closed or the phone is locked.
/// Same protocol as the website (api/video/r2-start-upload + r2-complete-upload);
/// the film request row is only created once every part has arrived, so an
/// interrupted upload never uses a game.
final class UploadManager: NSObject, ObservableObject {
    static let shared = UploadManager()

    enum State: String, Codable { case uploading, finishing, done, failed }

    struct Job: Codable, Identifiable {
        let id: String
        var ownerId: String
        var fileName: String
        var fileSize: Int64
        var contentType: String
        var sourcePath: String
        var key: String
        var uploadId: String
        var partSize: Int
        var partURLs: [Int: URL]
        var completed: [Int: String] = [:]
        var retries: [Int: Int] = [:]
        /// Game details arrive after the film starts uploading (the user fills them in meanwhile).
        var requested: RequestedGame?
        var jerseyColor: String?
        var state: State = .uploading
        var errorMessage: String?
        var gameVideoId: String?

        var totalParts: Int { partURLs.count }
        func partRange(_ n: Int) -> Range<Int64> {
            let start = Int64(n - 1) * Int64(partSize)
            return start..<min(start + Int64(partSize), fileSize)
        }
    }

    @Published private(set) var job: Job?
    @Published private(set) var progress: Double = 0

    var backgroundCompletionHandler: (() -> Void)?

    private let ioQueue = DispatchQueue(label: "netrix.upload.io", qos: .utility)
    private var inFlight: [Int: URLSessionTask] = [:]
    /// Parts whose file is being cut from the source video, not yet handed to the session.
    private var preparing: Set<Int> = []
    private var inFlightBytes: [Int: Int64] = [:]
    private let maxQueuedParts = 12

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: AppConfig.uploadSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForResource = 60 * 60 * 24
        let queue = OperationQueue.main
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private override init() {
        super.init()
        job = Self.loadJob()
        recomputeProgress()
        _ = session
    }

    // MARK: Paths

    private static var rootDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var jobFile: URL { rootDir.appendingPathComponent("job.json") }
    private static func jobDir(_ id: String) -> URL {
        let d = rootDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func partFile(_ id: String, _ n: Int) -> URL { jobDir(id).appendingPathComponent("part-\(n)") }

    private static func loadJob() -> Job? {
        guard let data = try? Data(contentsOf: jobFile) else { return nil }
        return try? JSONDecoder().decode(Job.self, from: data)
    }

    private func save() {
        guard let job else { try? FileManager.default.removeItem(at: Self.jobFile); return }
        if let data = try? JSONEncoder().encode(job) { try? data.write(to: Self.jobFile, options: .atomic) }
    }

    // MARK: Public

    var isBusy: Bool { job.map { $0.state == .uploading || $0.state == .finishing } ?? false }

    /// Copies the picked film into the app (so it survives until the upload finishes) and starts uploading.
    @MainActor
    func start(file: URL, ownerId: String) async throws {
        if isBusy { throw AppError(message: "Another game is still uploading. Wait for it to finish first.") }
        clearFinished()
        let id = UUID().uuidString
        let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension.lowercased()
        let dest = Self.jobDir(id).appendingPathComponent("source.\(ext)")
        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: file, to: dest)
        }.value
        let size = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw AppError(message: "That video file is empty.") }
        let contentType = ext == "mov" ? "video/quicktime" : (ext == "m4v" ? "video/x-m4v" : "video/mp4")
        let fileName = "game-film-\(Fmt.isoDay.string(from: Date())).\(ext)"

        let started: APIClient.StartUpload
        do {
            started = try await APIClient.startUpload(fileName: fileName, size: size, contentType: contentType, ownerId: ownerId)
        } catch {
            try? FileManager.default.removeItem(at: Self.jobDir(id))
            throw error
        }
        job = Job(id: id, ownerId: ownerId, fileName: fileName, fileSize: size, contentType: contentType,
                  sourcePath: dest.path, key: started.key, uploadId: started.uploadId, partSize: started.partSize,
                  partURLs: Dictionary(uniqueKeysWithValues: started.partUrls.map { ($0.partNumber, $0.url) }),
                  requested: nil, jerseyColor: nil)
        save()
        recomputeProgress()
        enqueueParts()
        if UserDefaults.standard.object(forKey: "notify.uploads") as? Bool ?? true {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Local notification about the upload, only while the app isn't on screen.
    private static func notify(_ title: String, _ body: String) {
        guard UserDefaults.standard.object(forKey: "notify.uploads") as? Bool ?? true else { return }
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Attaches the game details; the request row is created once every part has uploaded.
    @MainActor
    func attach(requested: RequestedGame, jerseyColor: String?) {
        guard var j = job else { return }
        j.requested = requested
        j.jerseyColor = jerseyColor
        job = j
        save()
        if j.state == .uploading && j.completed.count == j.totalParts { Task { await finish() } }
    }

    var awaitingDetails: Bool { job != nil && job?.requested == nil }

    /// Called at launch: re-attach to tasks the system kept running and queue whatever is missing.
    func resumeIfNeeded() {
        guard let job else { return }
        switch job.state {
        case .uploading:
            session.getAllTasks { [weak self] tasks in
                DispatchQueue.main.async {
                    guard let self else { return }
                    for t in tasks {
                        if let n = self.partNumber(of: t), t.state == .running || t.state == .suspended { self.inFlight[n] = t }
                    }
                    self.enqueueParts()
                }
            }
        case .finishing:
            Task { await finish() }
        case .done, .failed:
            break
        }
    }

    func retry() {
        guard var j = job, j.state == .failed else { return }
        j.state = (j.completed.count == j.totalParts && j.requested != nil) ? .finishing : .uploading
        j.errorMessage = nil
        j.retries = [:]
        job = j
        save()
        resumeIfNeeded()
    }

    func cancel() {
        guard let j = job else { return }
        for t in inFlight.values { t.cancel() }
        inFlight = [:]; inFlightBytes = [:]; preparing = []
        let key = j.key, uploadId = j.uploadId
        Task { await APIClient.abortUpload(key: key, uploadId: uploadId) }
        try? FileManager.default.removeItem(at: Self.jobDir(j.id))
        job = nil
        progress = 0
        save()
    }

    func clearFinished() {
        guard let j = job, j.state == .done || j.state == .failed && j.completed.isEmpty else { return }
        try? FileManager.default.removeItem(at: Self.jobDir(j.id))
        job = nil
        progress = 0
        save()
    }

    // MARK: Parts

    private func partNumber(of task: URLSessionTask) -> Int? {
        guard let desc = task.taskDescription, let j = job else { return nil }
        let parts = desc.split(separator: ":")
        guard parts.count == 2, String(parts[0]) == j.id else { return nil }
        return Int(parts[1])
    }

    private func enqueueParts() {
        guard let j = job, j.state == .uploading else { return }
        if j.completed.count == j.totalParts {
            if j.requested != nil { Task { await finish() } }
            return
        }
        let pending = (1...j.totalParts).filter { j.completed[$0] == nil && inFlight[$0] == nil && !preparing.contains($0) }
        let slots = max(0, maxQueuedParts - inFlight.count - preparing.count)
        let batch = Array(pending.prefix(slots))
        guard !batch.isEmpty else { return }
        let jobId = j.id, source = URL(fileURLWithPath: j.sourcePath)
        let ranges = batch.map { ($0, j.partRange($0), j.partURLs[$0]!) }
        // Reserve the slots now so a second call doesn't queue the same parts.
        for (n, _, _) in ranges { preparing.insert(n) }
        ioQueue.async { [weak self] in
            var ready: [(Int, URL, URL)] = []
            var failure: String?
            do {
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                for (n, range, url) in ranges {
                    let dest = Self.partFile(jobId, n)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try handle.seek(toOffset: UInt64(range.lowerBound))
                        let data = handle.readData(ofLength: Int(range.count))
                        try data.write(to: dest, options: .atomic)
                    }
                    ready.append((n, dest, url))
                }
            } catch {
                failure = "The video file couldn't be read. Pick it again."
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (n, _, _) in ranges { self.preparing.remove(n) }
                guard self.job?.id == jobId else { return }
                if let failure { self.fail(failure); return }
                for (n, file, url) in ready {
                    var request = URLRequest(url: url)
                    request.httpMethod = "PUT"
                    let task = self.session.uploadTask(with: request, fromFile: file)
                    task.taskDescription = "\(jobId):\(n)"
                    self.inFlight[n] = task
                    task.resume()
                }
            }
        }
    }

    private func fail(_ message: String) {
        Self.notify("Upload paused", message)
        Haptics.error()
        guard var j = job else { return }
        for t in inFlight.values { t.cancel() }
        inFlight = [:]; inFlightBytes = [:]
        j.state = .failed
        j.errorMessage = message
        job = j
        save()
    }

    private func recomputeProgress() {
        guard let j = job, j.fileSize > 0 else { progress = 0; return }
        if j.state == .done || j.state == .finishing { progress = 1; return }
        let done = j.completed.keys.reduce(Int64(0)) { $0 + Int64(j.partRange($1).count) }
        let flying = inFlightBytes.values.reduce(0, +)
        progress = min(1, Double(done + flying) / Double(j.fileSize))
    }

    // MARK: Finish

    @MainActor
    private func finish() async {
        guard var j = job, j.state != .done, let requested = j.requested else { return }
        j.state = .finishing
        job = j
        save()
        recomputeProgress()
        do {
            let parts = j.completed.map { APIClient.Part(PartNumber: $0.key, ETag: $0.value) }.sorted { $0.PartNumber < $1.PartNumber }
            try await APIClient.completeUpload(key: j.key, uploadId: j.uploadId, parts: parts, expectedSize: j.fileSize)
            struct NewVideo: Encodable {
                let user_id: String
                let requested_game: RequestedGame
                let storage_path: String
                let team_jersey_color: String?
                let status = "uploaded"
            }
            let rows: [GameVideo] = try await SupabaseClient.shared.insert("game_videos",
                NewVideo(user_id: j.ownerId, requested_game: requested, storage_path: j.key, team_jersey_color: j.jerseyColor))
            j.gameVideoId = rows.first?.id.value
            j.state = .done
            j.errorMessage = nil
            try? FileManager.default.removeItem(at: Self.jobDir(j.id))
            job = j
            save()
            NotificationCenter.default.post(name: .filmUploadFinished, object: nil)
            Self.notify("Game submitted", "Your film is uploaded. An analyst will review it shortly.")
        } catch {
            j.state = .failed
            j.errorMessage = error.localizedDescription
            job = j
            save()
        }
    }
}

extension Notification.Name {
    static let filmUploadFinished = Notification.Name("netrix.filmUploadFinished")
}

extension UploadManager: URLSessionTaskDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let n = partNumber(of: task) else { return }
        inFlightBytes[n] = totalBytesSent
        recomputeProgress()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let n = partNumber(of: task), var j = job else { return }
        inFlight[n] = nil
        inFlightBytes[n] = nil
        let http = task.response as? HTTPURLResponse
        if error == nil, let http, (200..<300).contains(http.statusCode),
           let etag = http.value(forHTTPHeaderField: "ETag") {
            j.completed[n] = etag
            job = j
            save()
            try? FileManager.default.removeItem(at: Self.partFile(j.id, n))
            recomputeProgress()
            enqueueParts()
            return
        }
        if (error as? URLError)?.code == .cancelled, j.state != .uploading { return }
        let attempts = (j.retries[n] ?? 0) + 1
        j.retries[n] = attempts
        job = j
        save()
        if attempts <= 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempts * 2)) { [weak self] in self?.enqueueParts() }
        } else {
            fail("The upload kept failing. Check your connection, then tap Try again.")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }
}
