# ROUND 2 (2026-11-13): phases, in the owner's order

No SwiftUI / UIKit / AVFoundation code from this round has been compiled or seen on a device. Logic is tested with the Swift
Linux toolchain (`swift test`); the UI passes `swiftc -parse` only.

## Phase 1: "CONNECTED but not really" on app open: DONE (logic tested), UI unverified

**Cause (found by reading the code):** the header chip said "online" as soon as the socket received `welcome`
(`AppModel.link == .online`), and the status line said "Connected" from the call phase alone. Nothing looked at whether the call audio
path was running, nothing timed out a `call_start` that the server never answered (a fatal `voice_error` left the call stuck
in "connecting the call" under a green chip), a socket that died while the app slept was trusted until the 15 s ping noticed, and
switching the address closed the old socket (the server ends the call on that) while the call state machine still said "active"
and never started a new call on the new socket.

**Fix:** `JarvisCore/ConnectionDisplay.swift` is a pure function of real facts (socket state, network path, liveness check,
call phase, audio engine running, address problem). `AppModel.display` publishes it; the chip, status line and orb use only
that. `.connected` needs socket open AND call active AND audio running AND no liveness check pending. States:
Connecting... / Checking connection... / Connected / Reconnecting... / Offline / Not connected, tap to retry (also the chip,
the orb and the status line are tappable) / Tap to talk (call ended on purpose) / Call blocked (microphone).
* Call-start watchdog (`CallModel`): 15 s after `call_start`, or at once on a fatal `voice_error`, the call is declared failed, audio is
  torn down, it retries by itself after 2 s, 5 s, 10 s, then waits for a tap (`AppModel.retryConnection`).
* Socket retry/backoff existed (0.25 s, 1, 2, 4 ... 15 s); after 4 failed attempts the UI says "Not connected, tap to retry".
  The address probe now runs from the first failed attempt: an HTML page (ngrok interstitial) or refused connection becomes the
  explanation and "Edit address" shows.
* Back from the background: the socket is pinged and must answer within 4 s ("Checking connection..."); a silent socket is
  closed and reconnected, the held call resumes. Wi-Fi <-> mobile data (`NetworkMonitor` notices the interface change) drops the
  old socket at once. Address switch / edit holds the call so the new welcome starts a fresh one.
* Tests (fake socket): server unreachable; socket opens but the call never starts (auto-retry, give up, manual retry, connected
  for real); fatal voice_error; resume from background with a live and with a dead socket; Wi-Fi to mobile; offline and back;
  address switch; plus pure-function tests of every display rule.
* Not verified: a real ngrok interstitial (tested against the local gateway's HTML page earlier, and by unit tests only), a real
  Wi-Fi to mobile switch, real background suspension.

**Test on the phone (Phase 1):**
1. Force-quit the app, open it: chip says "connecting..." then "online", the status "Connecting..." then "Connected" ONLY once you
   can talk to him (say something: the orb goes Listening). Mic permission prompt on first run still works.
2. Stop the Jarvis server (or switch Wi-Fi off and on the tunnel): status goes Reconnecting..., then "Not connected, tap to retry"
   within ~10 s; start the server again, tap it: Connected.
3. Put the app in the background for a minute, come back: briefly "Checking connection...", then Connected (or reconnects).
4. Wi-Fi -> mobile data with the app open: Reconnecting... then Connected within a few seconds, call resumes.
5. Point the address at an ngrok URL that shows the browser warning page: "Not connected" + the "Edit address" card.

## Phase 2: Mute / unmute ("the tap feature"): DONE (logic tested), earbud press UNVERIFIED on a device

Mute silences only the microphone frames sent to Jarvis (the server keeps the speech recogniser alive with silence, exactly as it
does for the browser). Socket, call and his voice stay up; unmute resumes on the next 40 ms frame. One source of truth: the call
state machine (`muted`), so every trigger ends in `CallModel.setMuted`:
* (a) the mic button, bottom left of Home: slashed mic on a filled orange disc, "MUTED" caption, orb dimmed + "Microphone muted"
  badge; tapping the orb also toggles it.
* (b) earbud / headset: `MPRemoteCommandCenter` togglePlayPause (press, headset hook), play = unmute, pause = mute, only while a
  call is on; `MPNowPlayingInfoCenter` filled and `playbackState` kept in step; a silent looping buffer in the audio engine keeps
  the output running so iOS treats the app as the Now Playing app with the phone locked.
* (c) lock screen / Control Center card: "Jarvis call", "Microphone on / muted", play-pause button.
* (d) iOS 17+: `AVAudioApplication` input-mute handler + notification (AirPods stem "mute" gesture, Control Center), behind
  `#available(iOS 17.0, *)`; our mute is pushed to the system too and released when the call ends.
* Survives Bluetooth route changes, interruptions, audio restarts, dropped sockets and reconnects (tests); a new call (after
  End, server `call_ended`, hold timeout, unpairing) starts unmuted. With no call there is nothing to mute.
* Tests: no frames while muted, voice still plays, no `call_end`, unmute at once, toggle idempotent, reconnect / interruption /
  route change / media reset, new call unmuted, server end clears it (`MuteTests`, `CallStateMachineTests`).
* **Honest status of the earbud press:** the media-key route is how every call/voice app does it, but whether iOS delivers a
  press to JarvisTalk (and not to Music or nothing) depends on iOS's Now Playing choice and was NOT tried on a real device. The
  AirPods "mute" gesture needs iOS 17+ and AirPods that support it. Fallbacks are in TROUBLESHOOTING.md.

**Test on the phone (Phase 2):**
1. In a call tap the mic button: icon turns into the slashed mic on orange, caption MUTED, orb dims. Talk: Jarvis does not react (his
   voice and the call continue). Tap again: he hears you at once.
2. Mute, switch to AirPods / Bluetooth and back, take a phone call or Siri interruption: still muted afterwards. Drop Wi-Fi for 10 s: still muted
   after the reconnect.
3. End the call and start a new one: unmuted.
4. Lock the phone, play-pause button on the lock screen / Control Center: the card says "Jarvis call", pressing toggles mute.
5. AirPods / wired earbuds: one press of the stem / centre button toggles mute with the phone locked in the pocket. Report if
   nothing happens or if Music starts instead. iOS 17+: also try the AirPods mute gesture.

# STATUS (written 2026-11-12, on the Linux laptop; nothing here has run on a Mac or an iPhone yet)

## In one paragraph

The protocol, networking, call logic, terminal emulator, camera-stream parser, orb maths, chat/deck/upload models and the
call flow are written, compiled with a real Swift 6.4.2 toolchain on Linux and tested (117 unit tests, plus a 56-check run
of the app's networking layer against the REAL Jarvis gateway). The iOS user interface and the Apple-framework glue
(SwiftUI, UIKit, AVFoundation, CoreMedia, Keychain) are written but could NOT be compiled here: they were syntax-checked
and reviewed by hand only. Expect to spend the first Mac session fixing a handful of compile errors there.

## Built

| Area | Where | State |
|---|---|---|
| **Dynamic base URL** (2026-11-12): one validator `Endpoint.parse` (bare host, host:port, http(s) URL, ngrok; http only for private / Tailscale), saved named addresses with a token per address in the Keychain, one-tap switch that moves session / terminals / cameras / uploads without re-pairing, Test connection (`ApiClient.probe`), Origin = Host of the current address on every request and socket, `ngrok-skip-browser-warning: 1` + non-browser User-Agent, HTML-instead-of-JSON error, "Edit address" after repeated failures | `JarvisCore/Endpoint.swift`, `ResponseSniffer.swift`, `JarvisNet/Http.swift`, `JarvisModel/SettingsStore.swift`, `AppModel.swift`, `UI/ServerAddressesView.swift`, `SettingsView`, `PairingView`, `HomeView` | logic unit-tested + real-server harness (second address of the same server: same token paired, Origin check, session socket); SwiftUI NOT compiled |
| Pairing (POST /api/pair, Origin == Host, cookie `jarvis_device` parsed from Set-Cookie, token in Keychain) | `JarvisNet/Http.swift`, `JarvisTalk/Platform/KeychainStore.swift`, `PairingView` | logic tested against the real server |
| Session socket with reconnect, backoff, 15 s ping / 20 s watchdog, `r/v/c` query like the web client, revoked-device detection | `JarvisNet/SessionConnection.swift` | tested (fake transport + real server) |
| Instant start: open app -> connect -> call starts silently (`call_start manual:false`); tap = `manual:true`; mute / end; hold 180 s and resume after a dropped socket; first-run, denied, restricted and changed-in-Settings microphone paths | `JarvisCore/CallStateMachine.swift`, `JarvisModel/CallModel.swift` | tested (state machine + full flows with fakes) |
| Voice audio: 16 kHz Int16 40 ms frames up, 24 kHz Int16 down, `voice_stop` cut, ducking, interruption / route / config-change / media-services-reset recovery, Bluetooth routes (system), lock screen + Control Center + headphone mute, route picker, background audio | `JarvisTalk/Platform/VoiceAudioEngine.swift`, `NowPlayingController.swift`, `JarvisCore/PCM.swift`, `Resampler.swift` | maths tested; engine NOT compiled (see below) |
| Orb: port of the web neural core (particles, rings, synapses with signals, listening ripples, thinking spin, speaking blink + waves, persona colours/shapes, mic/output levels, 30/60 fps, paused when hidden, lite mode) | `JarvisCore/NeuralCore.swift`, `JarvisTalk/UI/NeuralCoreView.swift` | maths tested; Canvas drawing NOT compiled |
| Chat: history, paging, streaming `text_delta`/`turn_done`, user messages, commands, approvals, tool chips, interrupted replies, voice captions in the same timeline, tasks, files, sessions (list / new / search) | `JarvisCore/Timeline.swift`, `JarvisModel/ChatModel.swift`, `DeckModel.swift`, `UI/ChatView.swift`, `MoreViews.swift` | reducer + models tested; views NOT compiled |
| Terminals: `/ws/terminal/{id}`, binary both ways, JSON resize, replay on reconnect, ANSI/VT emulator (colours, cursor, scroll regions, alt screen, UTF-8, wide chars, DEC line drawing, query replies), UIKit view with keyboard accessory row (Esc, Tab, Ctrl, arrows, ^C, ^D, paste), hardware keys, scrollback drag | `JarvisCore/TerminalBuffer.swift`, `TerminalEmulator.swift`, `JarvisModel/StreamSessions.swift`, `UI/TerminalView.swift` | emulator + socket tested (real shell via the real server); UIKit view NOT compiled |
| Cameras: list, live view (WS fMP4 -> own demuxer -> AVSampleBufferDisplayLayer), snapshot (+share, +save to Photos), record / stop, discover | `JarvisCore/FMP4.swift`, `UI/CamerasView.swift` | demuxer tested on a real ffmpeg clip with the server's exact flags; layer rendering NOT compiled or run |
| Files: list (shared / uploads), preview (image, text, PDF pages drawn by the server, Quick Look), share sheet, hide / delete, upload from Files picker, photo library, camera, with progress, retries, cancel | `JarvisNet/TransferSession.swift`, `Multipart.swift`, `JarvisModel/UploadModel.swift`, `UI/FilesView.swift`, `UploadController.swift` | upload / download / dedup tested on the real server; pickers and UI NOT compiled |
| Media library (list, upload, label), schedules (list, create, edit, pause / resume / run / snooze / cancel / delete), activity / tasks / approvals, recordings (status, stop), agents ("who answers"), voice + speed settings, settings screen | `JarvisModel/DeckModel.swift`, `UI/MoreViews.swift`, `SettingsView.swift` | schedules round trip tested on the real server; the rest decoded tolerantly; UI NOT compiled |
| Permissions: microphone, camera, (notifications structured, unused), local network string, Settings deep link, explanations for denied / restricted | `JarvisTalk/Platform/SystemPermissions.swift`, `UI/Permissions.swift`, `project.yml` | logic tested with fakes; system calls NOT compiled |
| Project: XcodeGen `project.yml` (Info.plist keys, background mode `audio`, usage strings, ATS local networking), assets (generated icon), README, TROUBLESHOOTING, docs/ARCHITECTURE | `project.yml` ... | `xcodegen` is not installed here: the YAML was NOT run through it |

## Verified here (Linux, Swift 6.4.2 official toolchain, installed in its own directory, signature checked)

* `swift build` of JarvisCore, JarvisNet, JarvisModel and the harness: clean.
* `swift test`: **117 tests, 0 failures** (JarvisCore 84, JarvisNet 10, JarvisModel 23):
  tolerant decoding of every server message, exact client message shapes, endpoint parsing (https / http / IPv6 / ports),
  Set-Cookie parsing, backoff, ISO dates, call state machine (15 scenarios), PCM / frame chunking / sample alignment /
  ducking / resampler (48 and 44.1 kHz -> 16 kHz, chunk independence), timeline reducer, terminal emulator (cursor, colours, scroll
  regions, alt screen, UTF-8 split across frames, resize, fuzzing with random bytes), fMP4 demuxer on a real ffmpeg clip (15
  frames, 3 key frames, any chunking, corrupted input never traps), orb maths, reconnect + watchdog + pong handling with a
  fake transport, call flows end to end with fake audio (instant start, mute, ducking, drop and resume, interruptions,
  permission denied / granted later, forget device, chat streaming, approvals).
* **Real-server harness** (`Harness/run_harness.sh`): starts the real Jarvis gateway from `project-jarvis` on a spare port with
  a throwaway data directory, scripted fake LLM and fake STT/TTS, a scrubbed environment (no keys), never the live server.
  The app's own networking layer then passed **56 of 56 checks** (9 new for the dynamic base URL: probe paired / unpaired / unreachable, the same token on a second Host of the same server (`localhost` vs `127.0.0.1`), `/api/me` and the session socket through it, a foreign Origin refused with 403, HTML where JSON is expected): health, unpaired state, wrong / reused code, pairing,
  `/api/me`, foreign Origin refused, bad token -> 401 and `.unauthorized`, welcome, text round trip folded by the timeline
  reducer, history, `call_start` + 50 silent 40 ms frames (server's STT received them), speech audio down, socket drop ->
  automatic reconnect -> `call_started{resumed:true}`, `call_end`, terminal open / echo / resize (`stty size`) / replay on
  reconnect / close / unknown id, 1.5 MB upload with progress, listing, download byte-for-byte, dedup, media upload + list,
  cameras / sessions / schedules (create, patch, pause, delete) decode.

## Only reviewed by hand (NOT compiled, NOT run): everything under `JarvisTalk/`

About 3000 lines of SwiftUI / UIKit / AVFoundation / CoreMedia / Security / Network code. Each file passes `swiftc -parse`
(syntax) and was read line by line against the API signatures, but no type check was possible without Apple SDKs.

## Dynamic base URL: what is NOT verified

* The new SwiftUI (`ServerAddressesView.swift` incl. `AddressEditor`, edits in `SettingsView`, `PairingView`, `HomeView`) passes
  `swiftc -parse` only; never compiled or run. Switching terminals / cameras live (`retarget`) is exercised by no test.
* Not tested against a real ngrok tunnel (no account / network here): the skip header, the User-Agent and the HTML detection
  are tested only against the local gateway (its web page stands in for ngrok's interstitial) and unit tests.
* `AppModel.switchTo` is tested for "unreachable" and "no token -> pairing"; the successful switch is covered by the harness
  at the networking level (probe + sockets), not through `AppModel`.
* iOS App Transport Security blocks plain http to hostnames (only IPs and local names are exempt): `http://x.ts.net` passes the
  validator but would be refused by iOS. Use https for names.
* Harness finding (Linux only): swift-corelibs-foundation truncates a WebSocket message above ~4 KB, so the big welcome of a
  busy server is cut and not decoded in the Linux harness; the harness opens the second-address socket early for that reason.
  Apple's URLSession is not known to have this problem, but it has not been checked.

## Must be checked on the Mac and the phone (in this order)

1. Project generates and builds (`xcodegen generate`, ⌘B); fix compile errors (likely spots in TROUBLESHOOTING).
2. Pairing over Tailscale works (then add the ngrok address in Settings and switch both ways: no re-pairing, terminals and cameras reconnect); the Keychain write succeeds; app relaunch reconnects by itself.
3. Microphone prompt (first run), then the call starts by itself; he speaks; you can talk over him (duck, then `voice_stop`).
   Check the voice processing format actually delivers audio (watch `silent_frames`-type symptoms: he never hears you) and that
   the mic is not silent when voice processing is on.
4. **Lock the phone in your pocket for 5+ minutes**: call stays up (server log `ws.open` / `ws.close`), lock-screen controls
   mute / unmute, switching Wi-Fi <-> mobile data recovers, a phone call / Siri interruption resumes the call, AirPods /
   wired headphones in and out.
5. Echo / loudness with voice processing on the loudspeaker (volume may be lower than the web page: voice-chat mode).
6. Orb: looks like the browser, 30/60 fps, no stutter, battery use acceptable when idle (30 fps) and hidden (0).
7. Terminal: typing, accessory row, Ctrl+C, arrows in vim / less, resize on rotation of the keyboard, paste, hardware keyboard.
8. Camera live view picture (needs a keyframe; first picture can take a second), snapshot share / save-to-Photos permission.
9. Uploads from Files, photo library (images and videos), camera; share sheet from Files tab; PDF preview.
10. Denied-permission paths on a real device: deny the microphone, then enable it in Settings and come back.

## Not done (honest list)

* Live work view cards (`exec_start` / `exec_end` with results) and the screen portals / reports / briefings / debriefs
  (`report_*`, `briefing_request`, `screen_cmd`). The phone does not send `screen_state`, so Jarvis does not treat it as a
  screen he can drive; he can still be heard and read on it. Briefings that want a screen are ignored.
* Starting screen / audio recordings from the phone (only status and stop for recordings that exist).
* Camera audio (the stream's AAC track is skipped; video only), HEVC streams, adding / removing cameras (add form), mic cameras.
* Per-agent voices and voice preview, Jarvis's persona colour while an agent is speaking (the orb follows `agents.active` only).
* Push / local notifications (permission service is structured, no UI asks yet), widgets, Siri / shortcuts.
* Uploads continue while the app is alive (the call keeps it alive); there is no background `URLSession`, so an upload
  started with no call running can pause when the app is suspended and retries when it returns.
* iPad layout (portrait iPhone only), light mode, localisation, VoiceOver was considered (labels on controls) but not tested.
* No UI tests; no Xcode unit-test target (tests live in the Swift package: `swift test` or Xcode's package scheme).
* `xcodegen` itself was not run; `project.yml` is conventional but unverified.

## Facts worth knowing

* The server needs no change. `/ws/*` accepts `Origin == Host` and the cookie; URLSession cannot read the server's custom close
  code `4401`, so a revoked device is detected by `GET /api/session` returning `paired:false`.
* Plain `http://` addresses are accepted only for local-network addresses (App Transport Security `NSAllowsLocalNetworking`).
* Xcode 15 or newer is assumed (UIKit is main-actor annotated there); the project builds in Swift 5 language mode.
