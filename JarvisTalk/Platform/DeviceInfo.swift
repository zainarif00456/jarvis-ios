import Foundation
import Network
import UIKit
import JarvisCore
import JarvisModel

/// Works out who this phone is (model, OS, name, a stable install id) and which kind of network it is on, and
/// publishes that so every request to Jarvis carries it. Self-contained: it has its own path monitor and touches
/// no call, mute or connection code.
final class DeviceInfo {
    private let secrets: SecretStore
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jarvis.deviceinfo")
    private var network: DeviceIdentity.Network = .other
    private var base: DeviceIdentity?
    private static let installKey = "installID"

    init(secrets: SecretStore) { self.secrets = secrets }

    /// Call on the main thread at launch.
    func start(deviceName: @escaping () -> String) {
        let id = installID()
        let model = Self.hardwareModel()
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let name = deviceName()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.base = DeviceIdentity(installID: id, model: model, name: name, os: os, appVersion: app, network: self.network)
            self.publish()
        }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.network = path.status != .satisfied ? .offline
                : path.usesInterfaceType(.wifi) ? .wifi
                : path.usesInterfaceType(.cellular) ? .cellular
                : path.usesInterfaceType(.wiredEthernet) ? .wired : .other
            self.publish()
        }
        monitor.start(queue: queue)
    }

    /// The owner can rename the phone in Settings; the next requests carry the new name.
    func rename(_ name: String) {
        queue.async { [weak self] in self?.base?.name = name; self?.publish() }
    }

    private func publish() {          // on `queue`
        guard var id = base else { return }
        id.network = network
        DeviceIdentity.publish(id)
    }

    private func installID() -> String {
        if let existing = secrets.read(Self.installKey), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        secrets.write(fresh, for: Self.installKey)
        return fresh
    }

    /// "iPhone14,3" style hardware identifier (the simulator reports its host model, which is fine).
    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
