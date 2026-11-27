import AVFoundation
import CoreMotion
import UIKit
import SwiftUI

/// Records a game straight from the iPhone camera in analysis quality.
///
/// Why record in the app: film picked from Photos or messaging apps is often
/// re-compressed, and phone footage tends to be zoomed, handheld or far away.
/// The analysis model needs a sharp, steady view of the goalie's net (the puck is
/// invisible at low resolution, see ml/README.md), and game sound helps it too.
///
/// - 1080p at 60 fps by default (4K 30 fps optional), HEVC, original quality.
/// - Stabilization off: on a tripod it only crops the picture.
/// - One file per period, joined without re-encoding when the game is finished.
@MainActor
final class GameRecorder: NSObject, ObservableObject {
    enum Quality: String, CaseIterable, Identifiable {
        case hd60 = "1080p · 60 fps", uhd30 = "4K · 30 fps"
        var id: String { rawValue }
        /// Approximate HEVC size per minute.
        var mbPerMinute: Double { self == .hd60 ? 100 : 170 }
        var detail: String { self == .hd60 ? "Recommended · about 6 GB per hour" : "Sharper · about 10 GB per hour" }
    }
    enum Lens: String, CaseIterable, Identifiable {
        case wide = "1×", ultraWide = "0.5×"
        var id: String { rawValue }
    }
    enum State: Equatable { case idle, preparing, ready, recording, finishing, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var periods: [URL] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var totalRecorded: TimeInterval = 0
    @Published private(set) var rollDegrees: Double = 0
    @Published private(set) var micAllowed = false
    @Published private(set) var focusLocked = false
    @Published private(set) var thermalWarning = false
    @Published var quality: Quality = .hd60 { didSet { if oldValue != quality { reconfigure() } } }
    @Published var lens: Lens = .wide { didSet { if oldValue != lens { reconfigure() } } }
    /// Also save the finished game to the user's Photos (off by default: it doubles the space needed).
    @Published var keepCopy = UserDefaults.standard.bool(forKey: "record.keepCopy") {
        didSet { UserDefaults.standard.set(keepCopy, forKey: "record.keepCopy") }
    }

    nonisolated let session = AVCaptureSession()
    nonisolated private let output = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioAdded = false
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObserver: NSKeyValueObservation?
    nonisolated private let sessionQueue = DispatchQueue(label: "netrix.recorder.session")
    private let motion = CMMotionManager()
    private var timer: Timer?
    private var startedAt: Date?
    weak var previewLayer: AVCaptureVideoPreviewLayer? { didSet { attachRotation() } }

    let gameId = UUID().uuidString
    var hasUltraWide: Bool { AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil }
    static var cameraAvailable: Bool { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil }

    private var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings/\(gameId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Setup

    func prepare() async {
        guard state == .idle else { return }
        guard Self.cameraAvailable else { state = .failed("This device has no back camera."); return }
        state = .preparing
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            state = .failed("NETRIX needs camera access to record games. Turn it on in Settings → NETRIX → Camera.")
            return
        }
        micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        configure()
        startMotion()
        NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    private func configure() {
        let quality = quality, lens = lens, mic = micAllowed && !audioAdded
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let s = self.session
            s.beginConfiguration()
            s.sessionPreset = .inputPriority
            for input in s.inputs {
                if let d = input as? AVCaptureDeviceInput, d.device.hasMediaType(.video) { s.removeInput(d) }
            }
            let type: AVCaptureDevice.DeviceType = lens == .ultraWide ? .builtInUltraWideCamera : .builtInWideAngleCamera
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else {
                s.commitConfiguration()
                Task { @MainActor in self.state = .failed("The camera couldn't be started.") }
                return
            }
            s.addInput(input)
            var addedMic = false
            if mic, let micDevice = AVCaptureDevice.default(for: .audio),
               let a = try? AVCaptureDeviceInput(device: micDevice), s.canAddInput(a) {
                s.addInput(a)
                addedMic = true
            }
            if !s.outputs.contains(self.output), s.canAddOutput(self.output) { s.addOutput(self.output) }
            Self.applyFormat(device, quality: quality)
            if let c = self.output.connection(with: .video) {
                if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
                if self.output.availableVideoCodecTypes.contains(.hevc) {
                    self.output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: c)
                }
            }
            // Fragments are written every few seconds, so a crash or a dead battery keeps the film up to that point.
            self.output.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            s.commitConfiguration()
            if !s.isRunning { s.startRunning() }
            Task { @MainActor in
                if addedMic { self.audioAdded = true }
                self.videoInput = input
                self.attachRotation()
                if self.state == .preparing || self.state == .idle { self.state = .ready }
            }
        }
    }

    private func reconfigure() {
        guard state == .ready else { return }
        configure()
    }

    /// Picks the highest-quality format at the wanted size and frame rate.
    nonisolated private static func applyFormat(_ device: AVCaptureDevice, quality: Quality) {
        let (w, fps): (Int32, Double) = quality == .hd60 ? (1920, 60) : (3840, 30)
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == w && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        // Prefer formats that aren't binned (full sensor detail).
        guard let format = candidates.first(where: { !$0.isVideoBinned }) ?? candidates.first else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        } catch {}
    }

    private func attachRotation() {
        guard let device = videoInput?.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        apply(coordinator)
        rotationObserver = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] c, _ in
            Task { @MainActor in self?.apply(c) }
        }
    }

    private func apply(_ c: AVCaptureDevice.RotationCoordinator) {
        let capture = c.videoRotationAngleForHorizonLevelCapture
        let preview = c.videoRotationAngleForHorizonLevelPreview
        let output = output
        sessionQueue.async {
            if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(capture), !output.isRecording {
                conn.videoRotationAngle = capture
            }
        }
        if let pc = previewLayer?.connection, pc.isVideoRotationAngleSupported(preview) { pc.videoRotationAngle = preview }
    }

    // MARK: Recording

    var periodLabel: String {
        let n = periods.count + (state == .recording || state == .finishing ? 0 : 1)
        return n <= 3 ? "Period \(n)" : (n == 4 ? "Overtime" : "Overtime \(n - 3)")
    }

    func startPeriod() {
        guard state == .ready else { return }
        let url = folder.appendingPathComponent("period-\(periods.count + 1).mov")
        try? FileManager.default.removeItem(at: url)
        UIApplication.shared.isIdleTimerDisabled = true
        state = .recording
        startedAt = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
        let output = output
        sessionQueue.async { [weak self] in
            guard let self else { return }
            output.startRecording(to: url, recordingDelegate: self)
        }
        Haptics.tap(.heavy)
    }

    func stopPeriod() {
        guard state == .recording else { return }
        state = .finishing
        let output = output
        sessionQueue.async { output.stopRecording() }
        Haptics.tap(.medium)
    }

    /// Tap-to-lock: fixes focus and exposure on the tapped point (rink lighting doesn't change).
    func lockFocus(at devicePoint: CGPoint) {
        guard let device = videoInput?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = devicePoint }
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
                device.unlockForConfiguration()
            } catch {}
        }
        focusLocked = true
        Haptics.select()
    }

    func unlockFocus() {
        guard let device = videoInput?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
            } catch {}
        }
        focusLocked = false
        Haptics.select()
    }

    /// Joins the periods into one film without re-encoding (no quality loss).
    func finishGame() async throws -> URL {
        guard !periods.isEmpty else { throw AppError(message: "Record at least one period first.") }
        teardown()
        if periods.count == 1 { return periods[0] }
        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError(message: "The periods couldn't be joined.")
        }
        let aTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for url in periods {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try vTrack.insertTimeRange(range, of: v, at: cursor)
                vTrack.preferredTransform = try await v.load(.preferredTransform)
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first { try aTrack?.insertTimeRange(range, of: a, at: cursor) }
            cursor = CMTimeAdd(cursor, duration)
        }
        let out = folder.appendingPathComponent("game.mov")
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw AppError(message: "The periods couldn't be joined.")
        }
        export.outputURL = out
        export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else {
            throw AppError(message: "The periods couldn't be joined: \(export.error?.localizedDescription ?? "unknown error").")
        }
        for p in periods { try? FileManager.default.removeItem(at: p) }
        return out
    }

    /// How the film was captured, saved with the request for the analyst and the model.
    var captureInfo: [String: String] {
        ["source": "netrix_ios_recorder", "quality": quality.rawValue, "lens": lens.rawValue,
         "stabilization": "off", "audio": micAllowed ? "on" : "off", "periods": "\(periods.count)"]
    }

    func discard() {
        teardown()
        try? FileManager.default.removeItem(at: folder)
        periods = []
    }

    func teardown() {
        timer?.invalidate(); timer = nil
        motion.stopDeviceMotionUpdates()
        UIApplication.shared.isIdleTimerDisabled = false
        rotationObserver = nil
        let output = output, session = session
        sessionQueue.async {
            if output.isRecording { output.stopRecording() }
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: Storage, level, heat

    /// Recording time that still fits on the phone at the chosen quality.
    var minutesLeft: Int { RecordingStorage.minutesLeft(mbPerMinute: quality.mbPerMinute) }

    /// Size of what's been recorded so far.
    var recordedBytes: Int64 {
        periods.reduce(Int64(0)) { sum, url in
            sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            // Held landscape, gravity runs along the phone's x axis when level;
            // any y component is the horizon tilt.
            let t = atan2(g.y, max(abs(g.x), 0.0001)) * 180 / .pi
            let tilt = g.x < 0 ? t : -t
            Task { @MainActor in self?.rollDegrees = tilt }
        }
    }

    @objc nonisolated private func thermalChanged() {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        Task { @MainActor in self.thermalWarning = hot }
    }
}

extension GameRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // A recording that stopped early (battery, storage, interruption) still has a usable file.
        let usable = FileManager.default.fileExists(atPath: outputFileURL.path)
        Task { @MainActor in
            self.timer?.invalidate(); self.timer = nil
            if let s = self.startedAt { self.totalRecorded += Date().timeIntervalSince(s) }
            self.startedAt = nil
            UIApplication.shared.isIdleTimerDisabled = false
            if usable { self.periods.append(outputFileURL) }
            if let error, !usable { self.state = .failed(error.localizedDescription); return }
            self.state = .ready
            Haptics.success()
        }
    }
}
