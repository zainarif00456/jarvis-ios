import XCTest
@testable import JarvisCore

final class ConnectionDisplayTests: XCTestCase {
    func resolve(_ socket: ConnectionInputs.Socket = .open, online: Bool = true, verifying: Bool = false, problem: String? = nil,
                 phase: CallStateMachine.Phase = .active, wants: Bool = true, audio: Bool = true) -> ConnectionDisplay {
        ConnectionDisplay.resolve(ConnectionInputs(socket: socket, networkOnline: online, verifying: verifying, addressProblem: problem,
                                                   callPhase: phase, wantsCall: wants, audioRunning: audio))
    }

    func testConnectedNeedsSocketCallAndAudio() {
        XCTAssertEqual(resolve(), .connected)
        XCTAssertNotEqual(resolve(audio: false), .connected, "no audio path: not connected")
        XCTAssertNotEqual(resolve(phase: .waitingServer), .connected)
        XCTAssertNotEqual(resolve(phase: .startingAudio), .connected)
        XCTAssertNotEqual(resolve(verifying: true), .connected, "an unverified socket is not connected")
        XCTAssertNotEqual(resolve(.connecting), .connected)
        XCTAssertNotEqual(resolve(.reconnecting(attempt: 1)), .connected)
        XCTAssertNotEqual(resolve(online: false), .connected)
        XCTAssertNotEqual(resolve(phase: .held), .connected)
    }

    func testHonestWordsForEachState() {
        XCTAssertEqual(resolve(.connecting, phase: .idle).statusText, "Connecting…")
        XCTAssertEqual(resolve(.reconnecting(attempt: 2)).statusText, "Reconnecting…")
        XCTAssertEqual(resolve(.reconnecting(attempt: ConnectionDisplay.failureAttempts)).statusText, "Not connected, tap to retry")
        XCTAssertTrue(resolve(.reconnecting(attempt: 9)).canRetry)
        XCTAssertEqual(resolve(.open, phase: .waitingServer).chipText, "connecting…")
        XCTAssertEqual(resolve(.open, phase: .blocked(.serverUnresponsive("x"))), .failed("x"))
        XCTAssertEqual(resolve(.open, phase: .idle, wants: false), .online)
        XCTAssertEqual(resolve(.open, phase: .idle, wants: false).chipText, "online")
        XCTAssertEqual(resolve(.open, phase: .blocked(.micDenied)), .callBlocked)
        XCTAssertEqual(resolve(.unauthorized), .notPaired)
        XCTAssertEqual(resolve(online: false), .offline)
    }

    func testAddressProblemWinsOverRetrying() {
        XCTAssertEqual(resolve(.reconnecting(attempt: 1), problem: "ngrok page"), .failed("ngrok page"))
        XCTAssertEqual(resolve(.connecting, problem: "ngrok page"), .failed("ngrok page"))
    }
}
