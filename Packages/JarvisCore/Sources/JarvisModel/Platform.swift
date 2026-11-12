import Foundation
import JarvisCore
import JarvisNet

// What the models need from the operating system, as small protocols. The iOS app provides the real
// implementations (Keychain, UserDefaults, AVAudioEngine, AVAudioSession permissions); tests provide fakes.

public protocol SecretStore: AnyObject {
    func read(_ key: String) -> String?
    func write(_ value: String, for key: String) -> Bool
    func delete(_ key: String)
}

public protocol SimpleDefaults: AnyObject {
    func string(_ key: String) -> String?
    func bool(_ key: String) -> Bool?
    func double(_ key: String) -> Double?
    func set(_ value: String?, for key: String)
    func set(_ value: Bool, for key: String)
    func set(_ value: Double, for key: String)
}

public final class MemorySecretStore: SecretStore {
    private var d: [String: String] = [:]
    public init() {}
    public func read(_ key: String) -> String? { d[key] }
    public func write(_ value: String, for key: String) -> Bool { d[key] = value; return true }
    public func delete(_ key: String) { d[key] = nil }
}

public final class MemoryDefaults: SimpleDefaults {
    private var d: [String: Any] = [:]
    public init() {}
    public func string(_ key: String) -> String? { d[key] as? String }
    public func bool(_ key: String) -> Bool? { d[key] as? Bool }
    public func double(_ key: String) -> Double? { d[key] as? Double }
    public func set(_ value: String?, for key: String) { d[key] = value }
    public func set(_ value: Bool, for key: String) { d[key] = value }
    public func set(_ value: Double, for key: String) { d[key] = value }
}

public enum PermissionState: Equatable, Sendable { case undetermined, granted, denied, restricted }

public protocol PermissionProvider: AnyObject {
    func microphone() -> PermissionState
    func requestMicrophone() async -> PermissionState
    func camera() -> PermissionState
    func requestCamera() async -> PermissionState
    func notifications() async -> PermissionState
    func requestNotifications() async -> PermissionState
}

public enum VoiceAudioEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(String)
    case mediaServicesReset
    case engineStopped          // the engine stopped by itself (configuration change)
}

/// Microphone in, speech out. The iOS implementation is AVAudioEngine with voice processing; see `VoiceAudioEngine`.
public protocol VoiceAudio: AnyObject {
    /// One 40 ms frame (1280 bytes, 16 kHz Int16 mono) and its RMS loudness. Called on the audio thread.
    var onMicFrame: (@Sendable (Data, Float) -> Void)? { get set }
    /// Loudness (0...~0.3) of what is being played, about 20 times a second while speech plays.
    var onOutputLevel: (@Sendable (Float) -> Void)? { get set }
    /// true when queued speech starts playing, false when the queue drained.
    var onPlaybackActive: (@Sendable (Bool) -> Void)? { get set }
    var onEvent: (@Sendable (VoiceAudioEvent) -> Void)? { get set }
    var routeName: String { get }
    func start() throws
    func stop()
    func restart() throws
    /// 24 kHz Int16 mono speech, arbitrary chunking.
    func play(_ pcm: Data)
    func cutPlayback()
    func setDucked(_ on: Bool)
}

public struct Platform {
    public var secrets: SecretStore
    public var defaults: SimpleDefaults
    public var permissions: PermissionProvider
    public var makeAudio: () -> VoiceAudio
    public var transport: WebSocketTransportProvider
    public var appVersion: String
    public init(secrets: SecretStore, defaults: SimpleDefaults, permissions: PermissionProvider, makeAudio: @escaping () -> VoiceAudio,
                transport: WebSocketTransportProvider = WebSocketTransportProvider(), appVersion: String = "1.0") {
        self.secrets = secrets; self.defaults = defaults; self.permissions = permissions; self.makeAudio = makeAudio
        self.transport = transport; self.appVersion = appVersion
    }
}

/// Lets tests swap the WebSocket transport (the default is the real URLSession one).
public struct WebSocketTransportProvider {
    public var make: () -> WebSocketTransport
    public init(make: @escaping () -> WebSocketTransport = { URLSessionTransport() }) { self.make = make }
}
