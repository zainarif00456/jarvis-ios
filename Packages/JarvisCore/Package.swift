// swift-tools-version:5.9
import PackageDescription

// JarvisCore: everything that does not need an Apple UI framework (protocol models, state machines,
// terminal emulator, fMP4 parser, PCM maths...). JarvisNet: URLSession based REST and WebSocket client
// (builds on Linux too, through FoundationNetworking). JarvisModel: the app's observable models (call, chat,
// deck, uploads, terminals, cameras) behind small platform protocols, so they are tested on Linux with fakes.
// The app target links all three; tests and the live-server harness run on Linux.
let package = Package(
    name: "JarvisCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .library(name: "JarvisNet", targets: ["JarvisNet"]),
        .library(name: "JarvisModel", targets: ["JarvisModel"]),
        .executable(name: "jarvis-harness", targets: ["jarvis-harness"]),
    ],
    targets: [
        .target(name: "JarvisCore"),
        .target(name: "JarvisNet", dependencies: ["JarvisCore"]),
        .target(name: "JarvisModel", dependencies: ["JarvisCore", "JarvisNet"]),
        .executableTarget(name: "jarvis-harness", dependencies: ["JarvisCore", "JarvisNet"]),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisNetTests", dependencies: ["JarvisCore", "JarvisNet"]),
        .testTarget(name: "JarvisModelTests", dependencies: ["JarvisCore", "JarvisNet", "JarvisModel"]),
    ]
)
