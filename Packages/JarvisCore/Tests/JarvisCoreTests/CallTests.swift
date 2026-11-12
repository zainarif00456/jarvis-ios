import XCTest
@testable import JarvisCore

final class CallStateMachineTests: XCTestCase {
    typealias M = CallStateMachine

    private func ready(granted: Bool = true) -> M {
        var m = M()
        m.handle(.micPermission(granted ? .granted : .undetermined))
        return m
    }

    func testInstantStartAfterPairing() {
        var m = ready()
        XCTAssertEqual(m.handle(.launched(paired: true, autoStart: true)), [.startAudio])
        XCTAssertEqual(m.phase, .startingAudio)
        XCTAssertEqual(m.handle(.audioStarted), [])            // socket not welcomed yet: wait
        XCTAssertEqual(m.phase, .waitingServer)
        XCTAssertEqual(m.handle(.socketWelcomed), [.sendCallStart(manual: false)])  // silent start, like the web page
        XCTAssertEqual(m.handle(.serverCallStarted(resumed: false)), [.cancelHoldTimer, .clearNotice])
        XCTAssertEqual(m.phase, .active); XCTAssertTrue(m.inCall)
    }

    func testWelcomeBeforeAudioStartsCallOnceAudioIsUp() {
        var m = ready()
        m.handle(.launched(paired: true, autoStart: true))
        XCTAssertEqual(m.handle(.socketWelcomed), [])
        XCTAssertEqual(m.handle(.audioStarted), [.sendCallStart(manual: false)])
    }

    func testFirstRunAsksForMicrophoneThenStarts() {
        var m = ready(granted: false)
        XCTAssertEqual(m.handle(.launched(paired: true, autoStart: true)), [.requestMicPermission])
        XCTAssertEqual(m.phase, .needsPermission)
        XCTAssertEqual(m.handle(.micPermission(.granted)), [.startAudio])
        XCTAssertEqual(m.phase, .startingAudio)
    }

    func testDeniedMicrophoneBlocksWithNoticeAndRecoversFromSettings() {
        var m = ready(granted: false)
        m.handle(.launched(paired: true, autoStart: true))
        let fx = m.handle(.micPermission(.denied))
        XCTAssertEqual(m.phase, .blocked(.micDenied))
        XCTAssertTrue(fx.contains { if case .notice = $0 { return true }; return false })
        // owner flips it on in Settings and comes back to the app
        XCTAssertEqual(m.handle(.foregrounded), [.requestMicPermission])
        XCTAssertEqual(m.handle(.micPermission(.granted)), [.startAudio])
    }

    func testRestrictedMicrophone() {
        var m = M()
        m.handle(.micPermission(.restricted))
        m.handle(.launched(paired: true, autoStart: true))
        XCTAssertEqual(m.phase, .blocked(.micRestricted))
    }

    func testNotPairedNeverStartsAudio() {
        var m = ready()
        XCTAssertEqual(m.handle(.launched(paired: false, autoStart: true)), [])
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.handle(.paired), [.startAudio])   // right after pairing: start
    }

    func testAutoStartOffWaitsForTap() {
        var m = ready()
        XCTAssertEqual(m.handle(.launched(paired: true, autoStart: false)), [])
        XCTAssertEqual(m.phase, .idle)
        let fx = m.handle(.userStartCall)
        XCTAssertEqual(fx, [.clearNotice, .startAudio])
        m.handle(.audioStarted)
        XCTAssertEqual(m.handle(.socketWelcomed), [.sendCallStart(manual: true)], "a tap is a manual start")
    }

    func testDroppedSocketHoldsAndResumes() {
        var m = ready()
        m.handle(.launched(paired: true, autoStart: true)); m.handle(.audioStarted); m.handle(.socketWelcomed); m.handle(.serverCallStarted(resumed: false))
        XCTAssertEqual(m.handle(.socketDropped), [.cutPlayback, .startHoldTimer(seconds: 180)])
        XCTAssertEqual(m.phase, .held); XCTAssertTrue(m.inCall)
        XCTAssertEqual(m.handle(.socketWelcomed), [.cancelHoldTimer, .sendCallStart(manual: false)])
        XCTAssertEqual(m.phase, .waitingServer)
        m.handle(.serverCallStarted(resumed: true))
        XCTAssertEqual(m.phase, .active)
    }

    func testHoldExpiryEndsAudioButKeepsWantingTheCall() {
        var m = ready()
        m.handle(.launched(paired: true, autoStart: true)); m.handle(.audioStarted); m.handle(.socketWelcomed); m.handle(.serverCallStarted(resumed: false))
        m.handle(.socketDropped)
        let fx = m.handle(.holdExpired)
        XCTAssertTrue(fx.contains(.stopAudio))
        XCTAssertEqual(m.phase, .idle); XCTAssertTrue(m.wantCall)
        XCTAssertEqual(m.handle(.socketWelcomed), [.startAudio], "when the server is back a fresh call starts by itself")
    }

    func testUserEndsCallOnPurposeAndItStaysOff() {
        var m = ready()
        m.handle(.launched(paired: true, autoStart: true)); m.handle(.audioStarted); m.handle(.socketWelcomed); m.handle(.serverCallStarted(resumed: false))
        let fx = m.handle(.userEndCall)
        XCTAssertEqual(fx.first, .sendCallEnd); XCTAssertTrue(fx.contains(.stopAudio))
        XCTAssertEqual(m.phase, .idle); XCTAssertFalse(m.wantCall)
        XCTAssertEqual(m.handle(.socketDropped), [])
        XCTAssertEqual(m.handle(.socketWelcomed), [], "an ended call is not restarted behind the owner's back")
    }

    func testServerEndingTheCall() {
        var m = ready()
        m.handle(.launched(paired: true, autoStart: true)); m.handle(.audioStarted); m.handle(.socketWelcomed); m.handle(.serverCallStarted(resumed: false))
        let fx = m.handle(.serverCallEnded(reason: "The call moved to a new connection."))
        XCTAssertTrue(fx.contains(.stopAudio)); XCTAssertTrue(fx.contains(.notice("The call moved to a new connection.")))
        XCTAssertEqual(m.phase, .idle); XCTAssertFalse(m.wantCall)
    }

    func testInterruptionRestartsAudio() {
        var m = ready()
        m.handle(.launched(paired: true, autoStart: true)); m.handle(.audioStarted); m.handle(.socketWelcomed); m.handle(.serverCallStarted(resumed: false))
        XCTAssertEqual(m.handle(.interruptionBegan), [.cutPlayback])
        XCTAssertEqual(m.handle(.interruptionEnded(shouldResume: true)), [.restartAudio])
        XCTAssertEqual(m.handle(.interruptionEnded(shouldResume: true)), [], "no double restart")
        XCTAssertEqual(m.handle(.mediaServicesReset), [.restartAudio])
    }

    func testAudioFailureBlocksAndTapRetries() {
        var m = ready()
        m.handle(.launched(paired: true, autoStart: true))
        let fx = m.handle(.audioFailed("no input"))
        XCTAssertEqual(m.phase, .blocked(.audioFailed("no input")))
        XCTAssertTrue(fx.contains(.notice("Could not start the audio: no input")))
        XCTAssertEqual(m.handle(.userStartCall), [.clearNotice, .startAudio])
    }

    func testUnpairedTearsDownEverything() {
        var m = ready()
        m.handle(.launched(paired: true, autoStart: true)); m.handle(.audioStarted); m.handle(.socketWelcomed); m.handle(.serverCallStarted(resumed: false))
        let fx = m.handle(.unpaired)
        XCTAssertTrue(fx.contains(.stopAudio)); XCTAssertFalse(fx.contains(.sendCallEnd))
        XCTAssertEqual(m.phase, .idle); XCTAssertFalse(m.wantCall)
    }

    func testMuteIsTrackedNotAnEffect() {
        var m = ready()
        XCTAssertEqual(m.handle(.setMuted(true)), []); XCTAssertTrue(m.muted)
    }
}
