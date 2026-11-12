# Architecture

```
SwiftUI views (JarvisTalk/UI) ── observe ──▶ models (JarvisModel) ── use ──▶ JarvisNet (REST, WebSockets)
                                                │                                  │
                                                ├─ CallModel ── CallStateMachine (JarvisCore, pure)
                                                ├─ ChatModel ── TimelineReducer   (JarvisCore, pure)
                                                ├─ DeckModel, UploadModel, TerminalSession, CameraStream
                                                └─ platform protocols ◀── implemented in JarvisTalk/Platform:
                                                     VoiceAudio (AVAudioEngine), SecretStore (Keychain),
                                                     PermissionProvider, SimpleDefaults
```

## Rules of thumb

* Anything that can be tested without Apple frameworks lives in `JarvisCore`/`JarvisNet`/`JarvisModel`, and is tested on Linux.
* The models talk to the OS only through small protocols (`Platform.swift`), so tests use fakes.
* All observable models are `@MainActor`. Audio callbacks run on audio threads and only touch `MicPipe` (lock protected).
* The token lives in the Keychain; logs never contain the token, the pairing code, or message text.
* Decoding is tolerant: unknown server message types become `.unknown`, bad bodies `.malformed`, bad list rows are dropped.

## The call

`CallStateMachine` (pure) takes events (launch, welcome, socket dropped, mic permission, audio started, server
`call_started`/`call_ended`, user tap, interruption...) and returns effects (start/stop/restart audio, send `call_start`
`{manual}` / `call_end`, hold timer, notices). `CallModel` runs the effects. Rules, as in the web page:

* a wanted call starts silently (`manual:false`) as soon as the socket has welcomed; a tap sends `manual:true`;
* a dropped socket parks the call: audio stays ready for 180 s while the socket reconnects, then `call_start{manual:false}`
  resumes it (the server keeps a parked call for 45 s);
* ending on purpose sends `call_end` and the call is not restarted until the owner taps again;
* the microphone is asked for once (first run); denied/restricted show guidance and recover when the app returns from Settings.

Audio (`VoiceAudioEngine`): `.playAndRecord` + `.voiceChat` + voice processing (echo cancellation), mic tap resampled to 16 kHz
Int16 by `StreamResampler`, chunked into exact 1280-byte (40 ms) frames; speech (24 kHz Int16) is aligned to whole samples
and scheduled on an `AVAudioPlayerNode`; `voice_stop` cuts the queue; local ducking (`DuckDetector`, port of js/voice.js)
softens playback while the owner starts talking. Interruptions, route changes, configuration changes and media-services
resets are observed and the engine is rebuilt. `UIBackgroundModes: audio` plus the active session keeps it all running locked.

## Sockets

`SessionConnection` (actor): one socket at a time, generation counted; reconnect backoff 0.25 s, 1 s, 2 s ... 15 s + jitter
(`Backoff`); ping every 15 s, dead if a ping is unanswered for 20 s (closed "going away", reconnect at once); the query
string reports `r`, `v`, and how the previous socket ended (`c`) like the web client. A socket that never reached `welcome`
triggers a `GET /api/session` check: `paired:false` means the device was revoked, so the state becomes `.unauthorized` and
the app shows the pairing screen (URLSession cannot report the server's 4401 close code, so this is the reliable signal).
Mic frames are dropped, not queued, when more than 50 are in flight.

Terminals and cameras use `StreamSocket` + `StreamRunner` (retry with backoff, give up after 6 failures with no data).
Terminal bytes feed `TerminalEmulator`; camera binary frames feed `FMP4Demuxer`, whose H.264 samples go to
`AVSampleBufferDisplayLayer` (hardware decode, show-immediately, wait for a keyframe after any gap).

## The orb

`NeuralCore.swift` is a port of the web client's `js/neural/{geometry,shaders,core}.js`: same Fibonacci layers and seeded
generator, same per-particle motion function (`NeuralShader.position`), same state machine for energy / listening ripples /
thinking spin / speaking blink and syllable waves (`CoreAnimator`), same persona colours and shapes. `NeuralCoreView` draws it
with SwiftUI `Canvas` inside a `TimelineView`: particles are batched into 12 paths per frame (alpha buckets), 1300 particles
(600 in Low Power Mode or thermal pressure), 60 fps while listening/thinking/speaking and 30 fps idle, paused when the
view is not visible or the app is not active.
