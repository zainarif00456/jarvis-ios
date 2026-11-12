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
