import Network
import Foundation

/// Tells the app when the network comes and goes, and when the route changes (Wi-Fi to mobile data), so a reconnect
/// starts at once instead of waiting for a timer. `interfaceChanged` is true when the path is online both before and
/// after but runs over a different interface: the old TCP connections are dead even though iOS did not say so.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jarvis.network")
    var onChange: ((_ online: Bool, _ interfaceChanged: Bool) -> Void)?
    private var lastKind: String?        // touched only on `queue`

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let online = path.status == .satisfied
            let kind: String = path.usesInterfaceType(.wifi) ? "wifi"
                : path.usesInterfaceType(.cellular) ? "cellular"
                : path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
            let changed = online && self.lastKind != nil && self.lastKind != kind
            if online { self.lastKind = kind }
            DispatchQueue.main.async { self.onChange?(online, changed) }
        }
        monitor.start(queue: queue)
    }
    func stop() { monitor.cancel() }
}
