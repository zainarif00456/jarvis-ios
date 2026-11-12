import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import JarvisCore
import JarvisModel

/// Everything between "the owner chose something" and `UploadModel.enqueue`: the Files picker, the photo library
/// (PhotosPicker needs no library permission: it runs out of process) and the camera.
@MainActor
final class UploadController: ObservableObject {
    @Published var showFiles = false
    @Published var showPhotos = false
    @Published var showCamera = false
    @Published var photoSelection: [PhotosPickerItem] = []
    @Published var message: String?
    /// Where the next batch goes: the files shared with Jarvis (chat attachments) or the media library.
    @Published var photoDestination: UploadItem.Destination = .media

    private var uploads: UploadModel?
    private var deviceName = "iPhone"
    private var alerts: PermissionAlerts?

    func configure(uploads: UploadModel, settings: SettingsStore, alerts: PermissionAlerts) {
        self.uploads = uploads; self.alerts = alerts; deviceName = settings.deviceName
    }

    func chooseFile() { showFiles = true }
    func choosePhoto(to destination: UploadItem.Destination = .media) { photoDestination = destination; showPhotos = true }
    func takePhoto() {
        Task {
            guard let alerts = alerts, await alerts.ensureCamera(purpose: "take a photo or video to send to Jarvis") else { return }
            showCamera = true
        }
    }

    // MARK: Files picker

    func handleFiles(_ result: Result<[URL], Error>) {
        guard let uploads = uploads else { return }
        switch result {
        case .failure(let e): message = "Could not open the file: \(e.localizedDescription)"
        case .success(let urls):
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let copy = try Self.copyToTemp(url, name: url.lastPathComponent)
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    if let refused = uploads.enqueue(fileURL: copy, name: url.lastPathComponent, mime: mime, destination: .files) { message = refused; try? FileManager.default.removeItem(at: copy) }
                } catch { message = "Could not read \(url.lastPathComponent): \(error.localizedDescription)" }
            }
        }
    }

    // MARK: Photo library

    func handlePhotos(_ items: [PhotosPickerItem]) async {
        guard let uploads = uploads, !items.isEmpty else { return }
        defer { photoSelection = [] }
        for (n, item) in items.enumerated() {
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "dat"
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            let base = "photo-\(Int(Date().timeIntervalSince1970))-\(n + 1)"
            do {
                let tmp: URL
                if type?.conforms(to: .movie) == true {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { message = "Could not load that video."; continue }
                    tmp = movie.url
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else { message = "Could not load that photo."; continue }
                    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
                    try data.write(to: tmp)
                }
                if let refused = uploads.enqueue(fileURL: tmp, name: "\(base).\(ext)", mime: mime, destination: photoDestination, source: "\(deviceName) photo library") {
                    message = refused; try? FileManager.default.removeItem(at: tmp)
                }
            } catch { message = "Could not load the photo: \(error.localizedDescription)" }
        }
    }

    // MARK: Camera

    func handleCamera(image: UIImage?, movie: URL?) {
        guard let uploads = uploads else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        if let image = image, let data = image.jpegData(compressionQuality: 0.85) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            do { try data.write(to: tmp) } catch { message = "Could not save the photo."; return }
            if let refused = uploads.enqueue(fileURL: tmp, name: "camera-\(stamp).jpg", mime: "image/jpeg", destination: .media, source: "\(deviceName) camera") { message = refused }
        } else if let movie = movie {
            do {
                let copy = try Self.copyToTemp(movie, name: "camera-\(stamp).mov")
                if let refused = uploads.enqueue(fileURL: copy, name: "camera-\(stamp).mov", mime: "video/quicktime", destination: .media, source: "\(deviceName) camera") { message = refused }
            } catch { message = "Could not read the video." }
        }
    }

    static func copyToTemp(_ url: URL, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(Format.safeFileName(name))
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in SentTransferredFile(movie.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(received.file.lastPathComponent)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// The system camera (photo or video). Needs NSCameraUsageDescription; the permission is checked before this opens.
struct CameraCapture: UIViewControllerRepresentable {
    var onResult: (UIImage?, URL?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        p.videoQuality = .typeHigh
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(_ p: CameraCapture) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            let movie = info[.mediaURL] as? URL
            parent.onResult(movie == nil ? image : nil, movie)
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Attaches the three pickers to a view. Use once per screen that offers uploads.
struct UploadPickers: ViewModifier {
    @ObservedObject var controller: UploadController
    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $controller.showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { controller.handleFiles($0) }
            .photosPicker(isPresented: $controller.showPhotos, selection: $controller.photoSelection, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .onChange(of: controller.photoSelection) { items in Task { await controller.handlePhotos(items) } }
            .fullScreenCover(isPresented: $controller.showCamera) {
                CameraCapture { image, movie in controller.handleCamera(image: image, movie: movie) }.ignoresSafeArea()
            }
    }
}
extension View { func uploadPickers(_ c: UploadController) -> some View { modifier(UploadPickers(controller: c)) } }
