import Network
import Foundation

/// Tells the app when the network comes and goes so a reconnect starts at once instead of waiting for a timer.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jarvis.network")
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.onChange?(online) }
        }
        monitor.start(queue: queue)
    }
    func stop() { monitor.cancel() }
}
