// ============================================================
// FILM FEATURIZER — raw frames on stdin -> compact per-frame features
// ============================================================
// ffmpeg decodes the film (streamed from R2) to small BGRA frames and
// pipes them here. For every frame we keep a motion grid; for every
// Nth frame an image embedding from Apple's Vision framework (runs on
// the Neural Engine / GPU, no Python ML stack needed). Video never
// touches the disk.
//
//   swiftc -O ml/detect/featurize.swift -o ml/detect/featurize
//   ffmpeg ... -vf fps=4,scale=320:180 -pix_fmt bgra -f rawvideo - \
//     | ml/detect/featurize 320 180 2 out/prefix
//
// Writes:
//   <prefix>.motion.f32  [frames x MOTION_DIMS] float32
//       0..31  mean |pixel change| vs previous frame, 8x4 grid
//       32..63 mean brightness, 8x4 grid (where the camera is pointing)
//       64     overall change
//   <prefix>.emb.f16     [frames/N x D] float16 Vision feature print
// Prints one JSON line: {"frames":..,"embeddings":..,"dim":..}

import Foundation
import Vision
import CoreVideo

let args = CommandLine.arguments
guard args.count == 5, let W = Int(args[1]), let H = Int(args[2]), let embEvery = Int(args[3]) else {
    FileHandle.standardError.write("usage: featurize WIDTH HEIGHT EMB_EVERY OUT_PREFIX\n".data(using: .utf8)!)
    exit(2)
}
let prefix = args[4]
let frameBytes = W * H * 4
let GX = 8, GY = 4
let MOTION_DIMS = GX * GY * 2 + 1

func openOut(_ path: String) -> FileHandle {
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)!
}
let motionOut = openOut(prefix + ".motion.f32")
let embOut = openOut(prefix + ".emb.f16")

// Read exactly n bytes from stdin (pipes return short reads).
let input = FileHandle.standardInput
func readFrame() -> Data? {
    var buf = Data(capacity: frameBytes)
    while buf.count < frameBytes {
        let chunk = input.readData(ofLength: frameBytes - buf.count)
        if chunk.isEmpty { return nil }
        buf.append(chunk)
    }
    return buf
}

// Luma at stride 2 for motion; previous frame kept for differencing.
let SW = W / 2, SH = H / 2
var prevLuma = [Float](repeating: 0, count: SW * SH)
var luma = [Float](repeating: 0, count: SW * SH)
var havePrev = false

var pixelBuffer: CVPixelBuffer?
CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
let request = VNGenerateImageFeaturePrintRequest()
if #available(macOS 14.0, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }

var frames = 0, embeddings = 0, dim = 0

while let frame = readFrame() {
    // ---- motion grid ----
    frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.bindMemory(to: UInt8.self)
        for y in 0..<SH {
            let row = (y * 2) * W * 4
            for x in 0..<SW {
                let i = row + (x * 2) * 4
                // BGRA -> luma
                luma[y * SW + x] = 0.114 * Float(p[i]) + 0.587 * Float(p[i + 1]) + 0.299 * Float(p[i + 2])
            }
        }
    }
    var change = [Float](repeating: 0, count: GX * GY)
    var bright = [Float](repeating: 0, count: GX * GY)
    var counts = [Float](repeating: 0, count: GX * GY)
    var total: Float = 0
    for y in 0..<SH {
        let cy = min(GY - 1, y * GY / SH)
        for x in 0..<SW {
            let cx = min(GX - 1, x * GX / SW)
            let c = cy * GX + cx
            let v = luma[y * SW + x]
            let d = havePrev ? abs(v - prevLuma[y * SW + x]) : 0
            change[c] += d
            bright[c] += v
            counts[c] += 1
            total += d
        }
    }
    var motion = [Float](repeating: 0, count: MOTION_DIMS)
    for c in 0..<(GX * GY) {
        motion[c] = change[c] / max(counts[c], 1) / 255
        motion[GX * GY + c] = bright[c] / max(counts[c], 1) / 255
    }
    motion[MOTION_DIMS - 1] = total / Float(SW * SH) / 255
    motion.withUnsafeBufferPointer { motionOut.write(Data(buffer: $0)) }
    swap(&prevLuma, &luma)
    havePrev = true

    // ---- embedding every Nth frame ----
    if frames % embEvery == 0, let pb = pixelBuffer {
        CVPixelBufferLockBaseAddress(pb, [])
        let dst = CVPixelBufferGetBaseAddress(pb)!
        let stride = CVPixelBufferGetBytesPerRow(pb)
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<H {
                memcpy(dst + y * stride, raw.baseAddress! + y * W * 4, W * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        var vec = [Float16](repeating: 0, count: max(dim, 1))
        do {
            try VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([request])
            if let obs = request.results?.first as? VNFeaturePrintObservation {
                let n = obs.elementCount
                if dim == 0 { dim = n; vec = [Float16](repeating: 0, count: n) }
                obs.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    if obs.elementType == .float {
                        let f = raw.bindMemory(to: Float.self)
                        for i in 0..<min(n, dim) { vec[i] = Float16(f[i]) }
                    } else {
                        let f = raw.bindMemory(to: Double.self)
                        for i in 0..<min(n, dim) { vec[i] = Float16(f[i]) }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write("vision: \(error)\n".data(using: .utf8)!)
        }
        // A failed frame still writes a zero row so rows stay aligned in time.
        if dim > 0 { vec.withUnsafeBufferPointer { embOut.write(Data(buffer: $0)) } }
        embeddings += 1
    }
    frames += 1
}

motionOut.closeFile()
embOut.closeFile()
print("{\"frames\":\(frames),\"embeddings\":\(embeddings),\"dim\":\(dim),\"motion_dims\":\(MOTION_DIMS)}")
