# Troubleshooting

## On the Mac, before the app runs

**`xcodegen: command not found`**: `brew install xcodegen`.

**"No such module 'JarvisCore'" / package not found**: run `xcodegen generate` from the folder that contains `project.yml`
(the package is referenced as `Packages/JarvisCore`). In Xcode: File, Packages, Reset Package Caches, then Resolve.

**Signing: "Signing for JarvisTalk requires a development team"**: Signing & Capabilities, choose your Team. If no team is
listed: Xcode, Settings, Accounts, add your Apple ID.

**"Failed to register bundle identifier"**: the id is taken. Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`, run
`xcodegen generate`, reopen the project.

**Phone is not listed / "Developer Mode disabled"**: unlock the phone, trust the Mac, Settings, Privacy & Security,
Developer Mode, On, restart. Then wait for Xcode to finish "Preparing device".

**"Untrusted Developer" when opening the app**: Settings, General, VPN & Device Management, trust your Apple ID.

**The app stops opening after 7 days**: free Apple ID builds expire; press ▶ in Xcode again.

## Compile errors (the Apple-only code was never compiled before)

The platform-independent code (`Packages/JarvisCore`) compiles and is tested. The files in `JarvisTalk/` use SwiftUI, UIKit,
AVFoundation and were reviewed against the API signatures by hand only. If the build fails, the places most likely to need a
one-line fix are:

* `JarvisTalk/Platform/VoiceAudioEngine.swift`: `AVAudioSession.CategoryOptions.allowBluetooth` was renamed
  `allowBluetoothHFP` in the newest SDK (the old name still compiles with a deprecation warning). `setVoiceProcessingEnabled`,
  `installTap` and `scheduleBuffer(_:completionCallbackType:)` are the other audio calls.
* `JarvisTalk/UI/CamerasView.swift`: the CoreMedia calls in `H264Renderer` (`CMVideoFormatDescriptionCreateFromH264ParameterSets`,
  `CMBlockBufferCreateWithMemoryBlock`, `CMSampleBufferCreateReady`, the sample attachments dictionary).
* `JarvisTalk/UI/TerminalView.swift`: `UIKeyInput` / `UITextInputTraits` conformance and the hardware key codes.
* `JarvisTalk/UI/NeuralCoreView.swift`: SwiftUI `Canvas` / `GraphicsContext` calls.
* `JarvisTalk/UI/UploadController.swift`: `PhotosPicker`, `Transferable` (`PickedMovie`).
* "Expression is too complex": split the long view expression into two properties.
* `onChange(of:)` deprecation warnings on iOS 17+ are harmless.

Warnings about `AVAudioSession.recordPermission` being deprecated (iOS 17) are expected; it still works.

## First run on the phone

**"Cannot reach the server"**: Tailscale must be on (both devices), and `tailscale serve` must be running on the laptop. Open
`https://<address>/health` in Safari on the phone: it should print `{"ok":true,...}`. If Safari cannot open it, it is not the app.

**"the secure connection failed (certificate)"**: the HTTPS address must be the Tailscale one (`*.ts.net`) that
`tailscale serve` shows. A plain IP over https has no certificate. Use `http://<lan-ip>:8000` only on the same Wi-Fi.

**"that code is invalid, used or expired"**: codes work once and for 10 minutes. Run `jarvis pair` again.

**"Too many attempts"**: the server allows 6 pairing attempts a minute; wait a minute.

**"The server refused the request (origin check)"**: the address typed does not match what the server sees as its Host
(for example a different port). Use exactly the address `tailscale serve` shows.

**Microphone is off**: Home shows *Open Settings* (Settings, Jarvis, Microphone). Coming back to the app starts the call.

**He hears himself / echo**: voice processing is on; use earphones or lower the volume. The orb's *stop* button cuts him off.

**Call drops when the phone locks**: check that Settings, Jarvis shows no "Background App Refresh" restriction, that Low Power
Mode is off for a first test, and look at the Jarvis server log for `ws.open` / `ws.close` lines. A call ends after
3 minutes without a connection (the server keeps the call for 45 s; the app keeps its audio ready for 3 minutes).

**Terminal shows nothing**: open the Terminal tab and tap *+*; the app opens `/ws/terminal/{id}` with the same cookie. A grey
"disconnected" badge means the server closed the socket (terminal closed or not found).

**Camera shows "only H.264 is supported"**: the server re-encodes camera streams to H.264; this message means a stream with another
codec reached the phone. Report the camera name.

**Pairing disappears after a while**: the server forgot this phone (you revoked it, or its database was reset). Pair again.

## Addresses (Tailscale / ngrok / LAN)

**"an ngrok warning page or the wrong URL"**: the address answered with HTML, not Jarvis. Usually the ngrok URL is stale
(free URLs change when ngrok restarts: copy the new `https://....ngrok-free.app` from the ngrok terminal and use **Edit
address**), or it points at another web server. Check that `https://<address>/health` shows `{"ok":true,...}` in Safari.

**The old address stopped working**: the home screen shows *Edit address* after a few failed reconnects; Settings, Server,
*Saved addresses* has Test connection and one-tap switching. Editing the active address keeps the pairing; if the server
there does not know this phone the pairing screen opens.

**"Plain http:// is only allowed for ... LAN, Tailscale, localhost"**: use `https://` for public names (ngrok is always
https). For `*.ts.net` names use https too: iOS blocks plain http to hostnames (it only exempts IP addresses and local names).

**"The server refused the request (origin check)"**: the Origin must equal the Host of the address in use; the app does this
itself, so this means a proxy in between rewrites the Host header. Use the address the proxy/tunnel prints.

**Switching says "not paired"**: that address leads to a different Jarvis server (or the server forgot this phone). Pair on it
with a new `jarvis pair` code; the other address keeps its own token.

## Checking the server side

* The server logs `ws.open` (with `ua=JarvisTalk-iOS`) when the app connects and `ws.close` with the close code.
* `GET /api/me` with the device cookie shows the device name.
* Revoking the phone on the laptop makes the app show the pairing screen with "no longer paired".

## Mute / earbud press does nothing (UNVERIFIED on a real device)

The earbud / headset press is mapped to mute through the media remote commands (play, pause, togglePlayPause). iOS only sends
them to the app it considers "Now Playing". If a press does nothing, or starts Music:
1. Make sure the call is up (status says Connected) and that Jarvis' card shows on the lock screen ("Jarvis call"). If the card is
   missing, the app is not Now Playing: start the call again, and close other audio apps (Music, Podcasts, YouTube) first.
2. Use the lock-screen / Control Center card or the mic button instead; they use the same mute.
3. iOS 17+ with AirPods: the "mute / unmute" stem gesture (Settings > the AirPods > Press once to mute, if offered) uses the system
   mute path (`AVAudioApplication`) which JarvisTalk also listens to.
4. Wired / third-party Bluetooth headsets differ: the hook button is `togglePlayPause`; double / triple press (next / previous track)
   are deliberately ignored.
5. If you find that the press reaches the app only when Jarvis was speaking recently, tell me: the silent keeper buffer in
   `VoiceAudioEngine` is the knob (it may need a real tiny non-zero signal or an `AVAudioPlayer`).
