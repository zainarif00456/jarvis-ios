import SwiftUI
import AVFoundation
import CoreMedia
import Photos
import JarvisCore
import JarvisModel

/// Decodes the camera's H.264 (parsed out of the fMP4 stream by `FMP4Demuxer`) with the hardware decoder through
/// AVSampleBufferDisplayLayer. Frames are shown as soon as they arrive (live view: no timebase, no buffering).
final class H264Renderer {
    private weak var layer: AVSampleBufferDisplayLayer?
    private var format: CMVideoFormatDescription?
    private var timescale: Int32 = 90_000
    private var needKeyframe = true

    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

    func setTrack(_ t: VideoTrack) {
        layer?.flush()
        needKeyframe = true
        timescale = Int32(max(1, t.timescale))
        format = Self.makeFormat(t)
    }

    func enqueue(_ samples: [VideoSample]) {
        guard let layer = layer, let format = format else { return }
        if layer.status == .failed { layer.flush(); needKeyframe = true }
        for s in samples {
            if needKeyframe { guard s.isSync else { continue }; needKeyframe = false }
            guard layer.isReadyForMoreMediaData else { needKeyframe = true; continue }   // fell behind: wait for the next keyframe
            if let sb = makeSample(s, format: format) { layer.enqueue(sb) }
        }
    }

    func flush() { layer?.flushAndRemoveImage(); needKeyframe = true }

    static func makeFormat(_ t: VideoTrack) -> CMVideoFormatDescription? {
        guard let sps = t.sps.first, let pps = t.pps.first else { return nil }
        var out: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                guard let sb = s.baseAddress, let pb = p.baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [sb, pb]
                let sizes: [Int] = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: Int32(t.nalLengthSize), formatDescriptionOut: &out)
            }
        }
        return status == noErr ? out : nil
    }

    private func makeSample(_ s: VideoSample, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let count = s.data.count
        guard count > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let buffer = block else { return nil }
        let copied = s.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(s.duration), timescale: timescale),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(s.pts), timescale: timescale),
                                        decodeTimeStamp: CMTime(value: CMTimeValue(s.dts), timescale: timescale))
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sb = sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary], let a = attachments.first {
            a[kCMSampleAttachmentKey_DisplayImmediately] = true
            if !s.isSync { a[kCMSampleAttachmentKey_NotSync] = true }
        }
        return sb
    }
}

final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) { super.init(frame: frame); displayLayer.videoGravity = .resizeAspect; backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct LiveVideo: UIViewRepresentable {
    let stream: CameraStream
    func makeUIView(context: Context) -> VideoLayerView {
        let v = VideoLayerView()
        let r = H264Renderer(layer: v.displayLayer)
        context.coordinator.renderer = r
        stream.onTrack = { r.setTrack($0) }
        stream.onSamples = { r.enqueue($0) }
        return v
    }
    func updateUIView(_ uiView: VideoLayerView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: H264Renderer? }
    static func dismantleUIView(_ uiView: VideoLayerView, coordinator: Coordinator) { coordinator.renderer?.flush() }
}

/// Saves a picture to the Photos library, asking for add-only access when needed and explaining a refusal.
enum PhotoSaver {
    static func save(_ image: UIImage) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
                return nil
            } catch { return "Could not save the photo: \(error.localizedDescription)" }
        case .denied: return "Photos access is off for Jarvis. Turn it on in Settings to save pictures."
        case .restricted: return "Saving to Photos is restricted on this iPhone."
        default: return "Photos access was not granted."
        }
    }
}

struct CamerasView: View {
    var isVisible: Bool
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var deck: DeckModel
    @State private var live: CameraInfo?
    @State private var snapshot: SnapshotItem?
    @State private var busy: Set<String> = []
    @State private var discovering = false
    @State private var discoverResult: String?

    struct SnapshotItem: Identifiable { let id = UUID(); let camera: CameraInfo; let image: UIImage }

    var body: some View {
        NavigationStack {
            ZStack {
                StageBackground(accent: Theme.accent(.jarvis))
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if deck.cameras.isEmpty {
                            EmptyHint(icon: "video.slash", title: "No cameras yet", detail: "Scan the network to find cameras, or ask Jarvis to add one.")
                        }
                        ForEach(deck.cameras) { cam in card(cam) }
                        if let r = discoverResult { Text(r).font(.footnote).foregroundColor(Theme.dimText).padding(.horizontal) }
                    }.padding(14)
                }
                .refreshable { await deck.loadCameras() }
            }
            .navigationTitle("Cameras").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionPill() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await discover() } } label: { if discovering { ProgressView() } else { Label("Discover", systemImage: "dot.radiowaves.left.and.right") } }
                        .disabled(discovering)
                }
            }
            .toolbarBackground(Theme.void, for: .navigationBar)
        }
        .task(id: isVisible) { if isVisible { await deck.loadCameras() } }
        .fullScreenCover(item: $live) { cam in LiveCameraView(camera: cam) }
        .sheet(item: $snapshot) { item in SnapshotView(item: item) }
    }

    private func card(_ cam: CameraInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: cam.kind == "mic" ? "mic.fill" : "video.fill").foregroundColor(Theme.accentLight(.jarvis))
                VStack(alignment: .leading) {
                    Text(cam.name).font(.headline).foregroundColor(Theme.text)
                    if let w = cam.where ?? cam.address { Text(w).font(.caption).foregroundColor(Theme.dimText).lineLimit(1) }
                }
                Spacer()
                PillLabel(text: cam.recording == true ? "recording" : (cam.state ?? "idle"), color: color(cam))
            }
            if let d = cam.detail, !d.isEmpty { Text(d).font(.caption).foregroundColor(Theme.warn) }
            HStack {
                if cam.canShowVideo { Button { live = cam } label: { Label("Watch", systemImage: "play.fill") }.buttonStyle(.borderedProminent) }
                if cam.canShowVideo {
                    Button { Task { await takeSnapshot(cam) } } label: { if busy.contains(cam.id) { ProgressView() } else { Label("Snapshot", systemImage: "camera") } }
                        .buttonStyle(.bordered).disabled(busy.contains(cam.id))
                }
                Button { Task { await deck.record(cam, seconds: 30, stop: cam.recording == true) } } label: {
                    Label(cam.recording == true ? "Stop" : "Record 30 s", systemImage: cam.recording == true ? "stop.circle" : "record.circle")
                }.buttonStyle(.bordered).tint(Theme.hot)
            }.font(.footnote)
        }
        .padding(14).glass()
        .accessibilityElement(children: .contain)
    }

    private func color(_ c: CameraInfo) -> Color {
        if c.recording == true { return Theme.hot }
        switch c.state { case "live": return Theme.ok; case "error", "failed": return Theme.bad; case "connecting", "starting": return Theme.warn; default: return Theme.dimText }
    }

    private func takeSnapshot(_ cam: CameraInfo) async {
        busy.insert(cam.id); defer { busy.remove(cam.id) }
        if let data = await deck.snapshot(cam, save: false), let img = UIImage(data: data) { snapshot = SnapshotItem(camera: cam, image: img) }
    }

    private func discover() async {
        discovering = true; defer { discovering = false }
        if let r = await deck.discoverCameras() {
            let found = r["found"]?.array?.count ?? r["cameras"]?.array?.count ?? 0
            discoverResult = r["message"]?.string ?? "Scan finished. \(found) found."
        } else { discoverResult = "The scan failed." }
    }
}

struct SnapshotView: View {
    let item: CamerasView.SnapshotItem
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    var body: some View {
        NavigationStack {
            VStack {
                Image(uiImage: item.image).resizable().scaledToFit().accessibilityLabel("Snapshot from \(item.camera.name)")
                if let m = message { Text(m).font(.footnote).foregroundColor(Theme.dimText).padding() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
            .navigationTitle(item.camera.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: Image(uiImage: item.image), preview: SharePreview(item.camera.name, image: Image(uiImage: item.image)))
                    Button { Task { message = await PhotoSaver.save(item.image) ?? "Saved to Photos." } } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("Save to Photos")
                }
            }
        }
    }
}

/// Full-screen live view of one camera.
struct LiveCameraView: View {
    let camera: CameraInfo
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var deck: DeckModel
    @Environment(\.dismiss) private var dismiss
    @State private var stream: CameraStream?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let s = stream {
                LiveVideo(stream: s).ignoresSafeArea()
                LiveOverlay(stream: s, camera: camera)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundColor(.white.opacity(0.9)) }
                        .accessibilityLabel("Close live view")
                    Spacer()
                    Text(camera.name).font(.headline).foregroundColor(.white)
                    Spacer()
                    Button { Task { await deck.record(camera, seconds: 30, stop: camera.recording == true) } } label: { Image(systemName: "record.circle").font(.system(size: 28)).foregroundColor(Theme.hot) }
                        .accessibilityLabel("Record 30 seconds")
                }.padding()
                Spacer()
            }
        }
        .onAppear {
            guard stream == nil, let s = app.cameraStream(for: camera) else { return }
            stream = s; s.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            stream?.stop(); stream = nil
            UIApplication.shared.isIdleTimerDisabled = app.settings.keepScreenAwake
        }
    }
}

struct LiveOverlay: View {
    @ObservedObject var stream: CameraStream
    let camera: CameraInfo
    var body: some View {
        VStack {
            Spacer()
            if let why = stream.unsupported {
                Text(why).font(.footnote).foregroundColor(Theme.warn).padding().background(Capsule().fill(Color.black.opacity(0.7)))
            } else {
                switch stream.status {
                case .live where stream.framesShown > 0: EmptyView()
                case .failed(let w): Text(w).foregroundColor(Theme.bad).padding().background(Capsule().fill(Color.black.opacity(0.7)))
                case .retrying: HStack { ProgressView(); Text("Reconnecting…") }.foregroundColor(.white).padding().background(Capsule().fill(Color.black.opacity(0.7)))
                default: HStack { ProgressView(); Text(stream.detail.isEmpty ? "Connecting to the camera…" : stream.detail) }.foregroundColor(.white).padding().background(Capsule().fill(Color.black.opacity(0.7)))
                }
            }
            Spacer().frame(height: 40)
        }
    }
}
