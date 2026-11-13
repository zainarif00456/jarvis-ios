import Photos
import Foundation
import JarvisCore
import JarvisModel

/// The PhotoKit side of automatic screenshot upload. Deliberately thin: it reports permission, lists images created
/// after a date (with the screenshot flag), copies one asset to a temp file and forwards library-change callbacks.
/// All decisions (what is new, dedupe, order, retries) are in `ScreenshotLedger` / `ScreenshotSyncModel`.
///
/// Permission: `.readWrite` is the lowest level that lets an app read library metadata and image data; `.addOnly` cannot
/// read. Limited access shows only picked photos, so it is reported as `.limited` and the app asks for full access.
final class PhotoScreenshotSource: NSObject, ScreenshotSource, PHPhotoLibraryChangeObserver {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var registered = false

    private func map(_ status: PHAuthorizationStatus) -> ScreenshotAccess {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func access() -> ScreenshotAccess { map(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    func requestAccess() async -> ScreenshotAccess {
        let current = access()
        guard current == .notDetermined else { return current }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return map(status)
    }

    func candidates(after date: Date) -> [ScreenshotCandidate] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@", date as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var found: [ScreenshotCandidate] = []
        result.enumerateObjects { asset, _, _ in
            guard let created = asset.creationDate else { return }
            found.append(ScreenshotCandidate(id: asset.localIdentifier, created: created,
                                             isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
        }
        return found
    }

    func export(id: String) async throws -> ExportedScreenshot {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ScreenshotSourceError.assetMissing
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first else {
            throw ScreenshotSourceError.exportFailed("the photo has no image data")
        }
        var ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = "png" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-\(UUID().uuidString).\(ext)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true        // the original may live in iCloud (Optimize Storage)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error = error {
                    continuation.resume(throwing: ScreenshotSourceError.exportFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        return ExportedScreenshot(fileURL: url, ext: ext)
    }

    func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        handler = onChange
        let needsRegister = !registered
        registered = true
        lock.unlock()
        if needsRegister { PHPhotoLibrary.shared().register(self) }
    }

    func stopObserving() {
        lock.lock()
        handler = nil
        let wasRegistered = registered
        registered = false
        lock.unlock()
        if wasRegistered { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    // Called by PhotoKit on an arbitrary queue.
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock()
        let callback = handler
        lock.unlock()
        callback?()
    }
}
