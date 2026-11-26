import SwiftUI
import AVFoundation
import UIKit

/// Lets one screen (the recorder) use landscape while the rest of the app stays portrait.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func set(_ new: UIInterfaceOrientationMask, rotateTo: UIInterfaceOrientationMask) {
        mask = new
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: rotateTo)) { _ in }
    }
}

/// Live camera picture.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayer: (AVCaptureVideoPreviewLayer) -> Void
    let onTap: (CGPoint) -> Void

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint) -> Void)?
        @objc func tapped(_ g: UITapGestureRecognizer) {
            onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: g.location(in: self)))
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        // Show the whole recorded frame (no cropping), so framing on screen is exactly what's filmed.
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        v.onTap = onTap
        v.addGestureRecognizer(UITapGestureRecognizer(target: v, action: #selector(PreviewView.tapped(_:))))
        DispatchQueue.main.async { onLayer(v.previewLayer) }
        return v
    }
    func updateUIView(_ v: PreviewView, context: Context) {}
}

/// Full-screen landscape recorder with framing guide, level, storage and period controls.
struct GameRecorderView: View {
    let onFinished: (URL, [String: String]) -> Void
    let onCancel: () -> Void
    @StateObject private var rec = GameRecorder()
    @State private var showGuide = false
    @State private var showFraming = true
    @State private var dimmed = false
    @State private var confirmDiscard = false
    @State private var joining = false
    @State private var error: String?
    @State private var battery: Float = UIDevice.current.batteryLevel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if GameRecorder.cameraAvailable {
                CameraPreview(session: rec.session, onLayer: { rec.previewLayer = $0 }, onTap: { p in
                    if rec.state == .ready || rec.state == .recording { rec.lockFocus(at: p) }
                })
                .ignoresSafeArea()
            } else {
                // Simulator / no camera: show the overlay over a stand-in rink so the layout can be checked.
                RinkFrameIllustration(showNet: true).opacity(0.45).ignoresSafeArea()
            }
            if showFraming { FramingGuide().allowsHitTesting(false) }
            controls
            if joining { joiningOverlay }
            if dimmed { dimOverlay }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            OrientationLock.set(.landscape, rotateTo: .landscapeRight)
            UIDevice.current.isBatteryMonitoringEnabled = true
            battery = UIDevice.current.batteryLevel
        }
        .onDisappear {
            rec.teardown()
            OrientationLock.set(.portrait, rotateTo: .portrait)
        }
        .task { await rec.prepare() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            battery = UIDevice.current.batteryLevel
        }
        .sheet(isPresented: $showGuide) { RecordingGuideView(onDone: { showGuide = false }) }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard \(rec.periods.count) period\(rec.periods.count == 1 ? "" : "s")", role: .destructive) { rec.discard(); onCancel() }
            Button("Keep recording", role: .cancel) {}
        } message: { Text("The film you've recorded will be deleted from this iPhone.") }
    }

    // MARK: Controls

    private var recording: Bool { rec.state == .recording }

    private var controls: some View {
        HStack(spacing: 0) {
            // Left: close, status, level
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    CircleIconButton(systemName: "xmark") {
                        if recording { return }
                        if rec.periods.isEmpty { rec.discard(); onCancel() } else { confirmDiscard = true }
                    }
                    .opacity(recording ? 0.35 : 1)
                    .accessibilityLabel("Close recorder")
                    statusPill
                }
                if rec.thermalWarning { warning("iPhone is hot — keep it out of direct heat", icon: "thermometer.sun") }
                if battery >= 0 && battery < 0.2 && UIDevice.current.batteryState != .charging {
                    warning("Battery \(Int(battery * 100))% — plug in a battery pack", icon: "battery.25")
                }
                if rec.minutesLeft < 90 && rec.state != .idle {
                    warning("Storage for about \(rec.minutesLeft) min left", icon: "internaldrive")
                }
                if case .failed(let msg) = rec.state { warning(msg, icon: "exclamationmark.triangle") }
                if let error { warning(error, icon: "exclamationmark.triangle") }
                Spacer()
                if !recording && !rec.periods.isEmpty { betweenPeriods }
                LevelIndicator(degrees: rec.rollDegrees)
            }
            .padding(.leading, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: record, finish, options
            VStack(spacing: 14) {
                Button { showGuide = true } label: { sideIcon("questionmark") }.accessibilityLabel("How to set up")
                Button { showFraming.toggle(); Haptics.select() } label: { sideIcon(showFraming ? "viewfinder.circle.fill" : "viewfinder") }
                    .accessibilityLabel(showFraming ? "Hide framing guide" : "Show framing guide")
                Button { rec.focusLocked ? rec.unlockFocus() : rec.lockFocus(at: CGPoint(x: 0.5, y: 0.5)) } label: {
                    sideIcon(rec.focusLocked ? "lock.fill" : "lock.open", tint: rec.focusLocked ? NX.warning : .white)
                }
                .accessibilityLabel(rec.focusLocked ? "Unlock focus and exposure" : "Lock focus and exposure")
                Spacer()
                recordButton
                Spacer()
                if recording {
                    Button { dimmed = true } label: { sideIcon("moon.fill") }.accessibilityLabel("Dim screen to save battery")
                } else {
                    optionsMenu
                }
                if !recording && !rec.periods.isEmpty {
                    Button(action: finish) {
                        Text("Finish").font(.sora(13, .semibold)).foregroundStyle(NX.navy)
                            .frame(width: 72, height: 36).background(Capsule().fill(NX.cream))
                    }
                    .accessibilityLabel("Finish game and continue")
                }
            }
            .padding(.trailing, 16).padding(.vertical, 14)
            .frame(width: 100)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            if recording {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(clock(rec.elapsed)).font(.sora(14, .semibold)).monospacedDigit()
            }
            Text(rec.periodLabel).font(.sora(13, .medium))
            Text("· \(rec.quality.rawValue)").font(.sora(12)).foregroundStyle(.white.opacity(0.7))
            if !rec.micAllowed && rec.state != .idle && rec.state != .preparing {
                Image(systemName: "mic.slash").font(.system(size: 11)).foregroundStyle(NX.warning)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 36)
        .background(Capsule().fill(recording ? Color.red.opacity(0.28) : Color.black.opacity(0.55)))
    }

    private var recordButton: some View {
        Button {
            recording ? rec.stopPeriod() : rec.startPeriod()
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                if recording {
                    RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 28, height: 28)
                } else {
                    Circle().fill(Color.red).frame(width: 60, height: 60)
                }
            }
        }
        .disabled(!(rec.state == .ready || rec.state == .recording))
        .opacity(rec.state == .ready || rec.state == .recording ? 1 : 0.4)
        .accessibilityLabel(recording ? "End \(rec.periodLabel)" : "Start recording \(rec.periodLabel)")
    }

    private var optionsMenu: some View {
        Menu {
            Section("Quality") {
                ForEach(GameRecorder.Quality.allCases) { q in
                    Button { rec.quality = q } label: {
                        Label("\(q.rawValue) — \(q.detail)", systemImage: rec.quality == q ? "checkmark" : "")
                    }
                }
            }
            if rec.hasUltraWide {
                Section("Lens") {
                    ForEach(GameRecorder.Lens.allCases) { l in
                        Button { rec.lens = l } label: {
                            Label(l == .wide ? "1× · sharpest (recommended)" : "0.5× · wider view, softer edges",
                                  systemImage: rec.lens == l ? "checkmark" : "")
                        }
                    }
                }
            }
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.55)).frame(width: 44, height: 44)
                Text(rec.lens.rawValue).font(.sora(13, .semibold)).foregroundStyle(.white)
            }
        }
        .accessibilityLabel("Recording quality and lens")
    }

    private var betweenPeriods: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(rec.periods.count) period\(rec.periods.count == 1 ? "" : "s") saved · \(clock(rec.totalRecorded))")
                .font(.sora(13, .semibold)).foregroundStyle(.white)
            Text("Teams switch ends: move the camera behind your goalie's net, then start \(rec.periodLabel).")
                .font(.sora(12)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.65)))
    }

    private var joiningOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.3)
            Text("Saving your game at full quality…").font(.sora(15, .semibold)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.75))
    }

    private var dimOverlay: some View {
        ZStack {
            Color.black
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Recording \(rec.periodLabel) · \(clock(rec.elapsed))").font(.sora(13, .medium)).monospacedDigit()
                }
                Text("Tap to wake").font(.sora(11)).opacity(0.6)
            }
            .foregroundStyle(.white.opacity(0.5))
        }
        .ignoresSafeArea()
        .onTapGesture { dimmed = false }
        .onAppear { UIScreen.main.brightness = max(0.05, UIScreen.main.brightness * 0.3) }
    }

    private func sideIcon(_ name: String, tint: Color = .white) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 44, height: 44).background(Circle().fill(Color.black.opacity(0.55)))
    }

    private func warning(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.sora(12, .medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(NX.error.opacity(0.75)))
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func finish() {
        joining = true
        Task {
            do {
                let url = try await rec.finishGame()
                let info = rec.captureInfo
                joining = false
                Haptics.success()
                onFinished(url, info)
            } catch {
                joining = false
                self.error = error.localizedDescription
            }
        }
    }
}

/// Rule-of-thirds lines plus where the goalie's net and the blue line should sit.
struct FramingGuide: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    for i in 1...2 {
                        p.move(to: CGPoint(x: w * CGFloat(i) / 3, y: 0)); p.addLine(to: CGPoint(x: w * CGFloat(i) / 3, y: h))
                        p.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 3)); p.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 3))
                    }
                }
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                // Blue line band near the top
                Rectangle().fill(NX.ice.opacity(0.18)).frame(height: 4).position(x: w / 2, y: h * 0.16)
                Text("Blue line near the top").font(.sora(11, .semibold)).foregroundStyle(NX.ice)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.5)))
                    .position(x: w / 2, y: h * 0.16 - 16)
                // Net zone near the bottom centre
                RoundedRectangle(cornerRadius: 10)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 6])).foregroundStyle(NX.cream.opacity(0.8))
                    .frame(width: w * 0.24, height: h * 0.2)
                    .position(x: w / 2, y: h * 0.74)
                Text("Your goalie's net here").font(.sora(11, .semibold)).foregroundStyle(NX.cream)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.5)))
                    .position(x: w / 2, y: h * 0.74 + h * 0.1 + 14)
            }
        }
    }
}

/// Horizon level: a bar that turns green within 1.5° of level.
struct LevelIndicator: View {
    let degrees: Double
    var level: Bool { abs(degrees) < 1.5 }
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 70, height: 2)
                Capsule().fill(level ? NX.success : Color.white).frame(width: 70, height: 3)
                    .rotationEffect(.degrees(max(-25, min(25, degrees))))
            }
            .frame(width: 76, height: 30)
            Text(level ? "Level" : String(format: "%.0f°", degrees)).font(.sora(12, .semibold))
                .foregroundStyle(level ? NX.success : .white).monospacedDigit()
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .animation(.easeOut(duration: 0.15), value: degrees)
        .accessibilityLabel(level ? "Camera is level" : "Camera tilted \(Int(degrees)) degrees")
    }
}
