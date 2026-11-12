import AVKit
import UIKit
import CoreMedia
import CoreVideo

/// Live execution status OUTSIDE the app: a Picture-in-Picture window (draggable and resizable by the system) that shows what
/// Jarvis is doing while the app is in the background or another app is open.
///
/// Why PiP and not a Live Activity: a Live Activity needs a Widget Extension target (own App ID and provisioning profile, an
/// App Group for sharing). Free Apple ID signing is limited in App IDs and extension support is unreliable there, and nothing
/// of it can be verified without a Mac, so PiP (works inside the app target, no extra entitlement) is implemented instead.
/// iOS cannot draw arbitrary overlays over other apps; PiP is the one system-sanctioned floating window.
///
/// NOT verified on a device. The frames are drawn with UIKit (title, running count, latest line) 4 times a second into a sample
/// buffer layer. Starting is manual from Settings (or the Home menu) and automatic when the app leaves the foreground while work
/// runs (iOS may refuse an automatic start; then use the manual button before leaving).
@MainActor
final class ExecPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    private let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var running = 0
    private var title = "Jarvis"
    private var detail = "idle"
    private var started = Date()
    private(set) var enabled = false
    var onActiveChanged: ((Bool) -> Void)?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on { prepare() } else { stop(); controller = nil }
    }

    /// From `ExecModel.onSummary`.
    func update(running: Int, title: String?, detail: String?) {
        if running > 0 && self.running == 0 { started = Date() }
        self.running = running
        self.title = title ?? "Jarvis"
        self.detail = detail ?? (running > 0 ? "working" : "idle")
    }

    private func prepare() {
        guard controller == nil, isSupported else { return }
        layer.videoGravity = .resizeAspect
        layer.frame = host.bounds
        host.layer.addSublayer(layer)
        host.alpha = 0.01
        (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first)?.addSubview(host)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        if #available(iOS 14.2, *) { c.canStartPictureInPictureAutomaticallyFromInline = true }
        controller = c
        enqueue()                      // a first frame so the layer has content
    }

    func start() {
        prepare()
        enqueue()
        controller?.startPictureInPicture()
    }
    func stop() { controller?.stopPictureInPicture(); timer?.invalidate(); timer = nil }
    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// The app is leaving the foreground: float the status if work is running.
    func appDidBackground() { if enabled, running > 0, !isActive { start() } }

    // MARK: drawing

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.enqueue() } }
    }

    private func enqueue() {
        guard let buffer = frame() else { return }
        if layer.status == .failed { layer.flush() }
        if layer.isReadyForMoreMediaData { layer.enqueue(buffer) }
    }

    private func frame() -> CMSampleBuffer? {
        let size = CGSize(width: 480, height: 270)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(red: 0.004, green: 0.02, blue: 0.035, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let tint = running > 0 ? UIColor(red: 0.3, green: 0.79, blue: 0.94, alpha: 1) : UIColor(white: 0.5, alpha: 1)
            tint.withAlphaComponent(0.6).setStroke()
            let frame = UIBezierPath(roundedRect: CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12), cornerRadius: 14); frame.lineWidth = 2; frame.stroke()
            // scan line while running
            if running > 0 {
                let t = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                tint.withAlphaComponent(0.25).setFill()
                ctx.fill(CGRect(x: 8, y: 8 + CGFloat(t) * (size.height - 24), width: size.width - 16, height: 6))
            }
            let head: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 18, weight: .bold), .foregroundColor: tint]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular), .foregroundColor: UIColor(white: 0.93, alpha: 1)]
            let sub: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: UIColor(white: 0.65, alpha: 1)]
            (running > 0 ? "JARVIS · \(running) WORKING" : "JARVIS · IDLE").draw(at: CGPoint(x: 22, y: 22), withAttributes: head)
            (title as NSString).draw(in: CGRect(x: 22, y: 70, width: size.width - 44, height: 80), withAttributes: body)
            (detail as NSString).draw(in: CGRect(x: 22, y: 160, width: size.width - 44, height: 60), withAttributes: sub)
            if running > 0 {
                let s = Int(Date().timeIntervalSince(started))
                String(format: "%02d:%02d", s / 60, s % 60).draw(at: CGPoint(x: size.width - 90, y: 22), withAttributes: sub)
            }
        }
        guard let cg = img.cgImage else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buf, formatDescriptionOut: &fd)
        guard let desc = fd else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buf, formatDescription: desc, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb = sb, let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    // MARK: AVPictureInPictureControllerDelegate
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.startTimer(); self.onActiveChanged?(true) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.timer?.invalidate(); self.timer = nil; self.onActiveChanged?(false) }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate (a live stream: always "playing", no seeking)
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
}
