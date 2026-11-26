import SwiftUI
import PhotosUI
import UIKit

// MARK: - Encoding (matches the website: 200×200 JPEG data URL, under 60,000 characters)

enum AvatarCodec {
    static let side: CGFloat = 200
    static let maxLength = 60_000

    private static let cache = NSCache<NSString, UIImage>()

    static func image(from dataURL: String?) -> UIImage? {
        guard let dataURL, dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let key = NSString(string: String(dataURL.suffix(64)) + "\(dataURL.count)")
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Square image → data URL, lowering JPEG quality until it fits the database limit.
    static func dataURL(from square: UIImage) -> String? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            square.draw(in: CGRect(origin: .zero, size: size))
        }
        for q in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let jpg = resized.jpegData(compressionQuality: q) {
                let url = "data:image/jpeg;base64," + jpg.base64EncodedString()
                if url.count <= maxLength { return url }
            }
        }
        return nil
    }
}

// MARK: - Display

/// Profile photo, or initials when there's no photo.
struct AvatarView: View {
    let profile: Profile?
    var size: CGFloat = 40
    var style: Style = .light
    enum Style { case light, brand }

    var body: some View {
        Group {
            if let img = AvatarCodec.image(from: profile?.avatarURL) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Text(profile?.initials ?? "N")
                    .font(.sora(size * 0.36, .semibold))
                    .foregroundStyle(style == .light ? NX.navy : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(style == .light
                                ? AnyShapeStyle(Color.white)
                                : AnyShapeStyle(LinearGradient(colors: [NX.royal, NX.navy], startPoint: .top, endPoint: .bottom)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(profile?.fullName.map { "\($0), profile photo" } ?? "Profile photo")
    }
}

// MARK: - Editing

/// Tap target on the Profile screen: photo with a camera badge and a menu to change or remove it.
struct AvatarEditor: View {
    @EnvironmentObject private var app: AppState
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var cropSource: CropSource?
    @State private var saving = false

    struct CropSource: Identifiable { let id = UUID(); let image: UIImage }

    var body: some View {
        Menu {
            Button { showPicker = true } label: { Label("Choose from library", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take photo", systemImage: "camera") }
            }
            if app.me?.avatarURL != nil {
                Button(role: .destructive) { save(nil) } label: { Label("Remove photo", systemImage: "trash") }
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(profile: app.me, size: 84, style: .brand)
                    .overlay(Circle().stroke(NX.borderStrong))
                    .opacity(saving ? 0.5 : 1)
                    .overlay { if saving { ProgressView().tint(.white) } }
                Image(systemName: "camera.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(NX.navy)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(NX.cream))
                    .overlay(Circle().stroke(NX.base, lineWidth: 2))
            }
        }
        .accessibilityLabel("Change profile photo")
        .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    cropSource = CropSource(image: img.normalizedUp())
                } else {
                    app.toast = Toast("That photo couldn't be opened", style: .error)
                }
                pickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in cropSource = CropSource(image: img.normalizedUp()) }.ignoresSafeArea()
        }
        .fullScreenCover(item: $cropSource) { src in
            AvatarCropView(image: src.image) { square in
                guard let url = AvatarCodec.dataURL(from: square) else {
                    app.toast = Toast("That photo is too detailed to save. Try another.", style: .error); return
                }
                save(url)
            }
        }
    }

    private func save(_ dataURL: String?) {
        guard let id = app.me?.id else { return }
        saving = true
        Task {
            do {
                let _: [Profile] = try await SupabaseClient.shared.update("profiles", query: "id=eq.\(id)", AvatarPatch(avatar_url: dataURL))
                await app.profileUpdated()
                if app.selectedGoalieId == id { await app.refreshStore() }
                app.toast = Toast(dataURL == nil ? "Photo removed" : "Photo updated", style: .success)
            } catch {
                app.toast = Toast("Couldn't save the photo", message: error.localizedDescription, style: .error)
            }
            saving = false
        }
    }
}

/// Move and pinch to frame the photo in a circle, like the iOS contact photo editor.
struct AvatarCropView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width - 40, 340)
            let base = baseSize(for: d)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: base.width * scale, height: base.height * scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            DragGesture()
                                .onChanged { v in offset = clamp(CGSize(width: lastOffset.width + v.translation.width,
                                                                       height: lastOffset.height + v.translation.height), base: base, d: d) }
                                .onEnded { _ in lastOffset = offset },
                            MagnificationGesture()
                                .onChanged { v in scale = min(max(lastScale * v, 1), 5); offset = clamp(offset, base: base, d: d) }
                                .onEnded { _ in lastScale = scale; lastOffset = offset }
                        )
                    )
                // Dim everything outside the circle.
                Rectangle().fill(Color.black.opacity(0.6))
                    .mask(ZStack { Rectangle(); Circle().frame(width: d, height: d).blendMode(.destinationOut) }.compositingGroup())
                    .allowsHitTesting(false)
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5).frame(width: d, height: d).allowsHitTesting(false)
                VStack {
                    Text("Move and scale").font(.nxLabel).foregroundStyle(.white).padding(.top, NX.S.l)
                    Spacer()
                    HStack {
                        Button("Cancel") { dismiss() }.font(.sora(16)).foregroundStyle(.white).frame(minWidth: 80, minHeight: 44)
                        Spacer()
                        Button("Use photo") {
                            onDone(render(d: d, base: base))
                            Haptics.success()
                            dismiss()
                        }
                        .buttonStyle(.nxPrimary).frame(width: 150)
                    }
                    .padding(.horizontal, NX.margin).padding(.bottom, NX.S.l)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .preferredColorScheme(.dark)
    }

    /// The image's on-screen size at scale 1: just covers the circle.
    private func baseSize(for d: CGFloat) -> CGSize {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return CGSize(width: d, height: d) }
        let k = d / min(w, h)
        return CGSize(width: w * k, height: h * k)
    }

    private func clamp(_ o: CGSize, base: CGSize, d: CGFloat) -> CGSize {
        let maxX = max(0, (base.width * scale - d) / 2), maxY = max(0, (base.height * scale - d) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }

    /// Crops the part of the photo inside the circle into a square image.
    private func render(d: CGFloat, base: CGSize) -> UIImage {
        let shown = CGSize(width: base.width * scale, height: base.height * scale)
        let pxPerPt = image.size.width / shown.width
        let originX = (shown.width - d) / 2 - offset.width
        let originY = (shown.height - d) / 2 - offset.height
        let crop = CGRect(x: originX * pxPerPt, y: originY * pxPerPt, width: d * pxPerPt, height: d * pxPerPt)
        let out = CGSize(width: 400, height: 400)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: out, format: format).image { _ in
            let k = out.width / crop.width
            image.draw(in: CGRect(x: -crop.minX * k, y: -crop.minY * k, width: image.size.width * k, height: image.size.height * k))
        }
    }
}

/// System camera for taking a profile photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.cameraDevice = .front
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

extension UIImage {
    /// Redraws photos taken sideways so cropping math works in display orientation.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
