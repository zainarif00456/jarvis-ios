# Jarvis for iOS (JarvisTalk)

A native iPhone app that mirrors the Jarvis browser deck: open it and it connects to your Jarvis server and starts the
voice call by itself (it keeps running with the phone locked), plus the admin chat, live terminals, live cameras,
files and uploads (Files picker, photo library, camera), media library, schedules and settings. The orb is the same
neural core as the web client, ported to SwiftUI.

It speaks the existing gateway protocol (`project-jarvis/docs/protocol.md`). **No change to the Jarvis server is needed.**

**Read `STATUS.md` first**: it says exactly what was compiled and tested on Linux and what has only been reviewed by
hand and must be checked on the Mac and the phone.

## Layout

```
project.yml                     XcodeGen project (generates JarvisTalk.xcodeproj)
Packages/JarvisCore/            Swift package, builds and is tested on Linux too
  Sources/JarvisCore            pure logic: protocol models, call state machine, PCM maths, timeline reducer,
                                terminal emulator, fMP4 demuxer, orb maths, reconnect backoff
  Sources/JarvisNet             URLSession REST + WebSocket client (pairing, reconnect, watchdog, uploads)
  Sources/JarvisModel           observable app models (call, chat, deck, uploads, terminal, camera) behind small
                                platform protocols (Keychain, audio engine, permissions) so they are tested with fakes
  Sources/jarvis-harness        runs JarvisNet/JarvisCore against a real Jarvis gateway
  Tests/                        106 unit tests
JarvisTalk/                     the iOS app target (Apple frameworks only: SwiftUI, UIKit, AVFoundation, ...)
  App/                          @main, app wiring, tabs
  Platform/                     Keychain, AVAudioEngine voice engine, permissions, lock-screen controls, network monitor
  UI/                           screens: Home (orb + deck), Chat, Terminal, Cameras, Files, Media, Schedules, Settings
Harness/                        run_harness.sh + fake_server.py: end-to-end run against a real local gateway
docs/ARCHITECTURE.md            how the pieces fit
TROUBLESHOOTING.md              first-run errors and fixes
```

## Build and run on the Mac (Xcode, install straight to the iPhone, no App Store)

1. Install **Xcode 15 or newer** from the Mac App Store and open it once (accept the licence, let it install components).
2. Install XcodeGen: `brew install xcodegen` (no Homebrew? `https://brew.sh`, or download XcodeGen from its GitHub releases).
3. Copy this folder to the Mac (git clone, or zip and AirDrop), then:
   ```sh
   cd jarvis-ios
   xcodegen generate          # creates JarvisTalk.xcodeproj from project.yml
   open JarvisTalk.xcodeproj
   ```
4. Xcode resolves the local package `Packages/JarvisCore` by itself (wait for "Resolving packages" to finish).
5. Select the **JarvisTalk** target, tab **Signing & Capabilities**: tick *Automatically manage signing* and choose your
   **Team** (sign in with your Apple ID under Xcode, Settings, Accounts if none is listed). If Xcode says the bundle
   identifier is taken, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` (for example `com.yourname.jarvis`) and run
   `xcodegen generate` again.
6. **Build once with ⌘B before running.** The Apple-framework code could not be compiled on the Linux laptop, so fix
   any compile error first (see `TROUBLESHOOTING.md`, "Compile errors": the likely spots are listed there).
7. Plug in the iPhone, unlock it, tap *Trust* on the phone. On the phone enable **Settings, Privacy & Security,
   Developer Mode** (it restarts the phone). In Xcode choose the iPhone as the run destination and press ▶.
8. First launch on the phone: *Settings, General, VPN & Device Management*, tap your Apple ID under "Developer App", Trust.
   A free Apple ID build expires after 7 days (press ▶ again to refresh); a paid account lasts a year.

Optional, on the Mac: `cd Packages/JarvisCore && swift test` runs all 117 unit tests natively.

## First use

1. The phone needs **Tailscale** on, and the laptop must serve Jarvis over HTTPS (`tailscale serve`; the address looks
   like `my-laptop.tail1234.ts.net`).
2. On the laptop run `jarvis pair`. It prints a one-time code (valid 10 minutes).
3. In the app enter the address, the code and a name for the phone, then **Pair**. The token goes to the iOS Keychain.
4. Allow the microphone when asked. The call starts by itself; talk. From now on opening the app connects at once and
   starts the call (switch that off in Settings, *Start the call when the app opens*).
5. Lock the phone: the call keeps going. Lock-screen / Control Center / headphone play-pause toggles the mute.

### Server addresses (Tailscale, ngrok, LAN) — the base URL is not fixed

The address field takes any of: `my-laptop.tail1234.ts.net`, `host:8443`, `https://abc-12-34.ngrok-free.app/`,
`http://192.168.1.5:8000` (paths, queries and trailing slashes are dropped). Plain `http://` is only accepted for local
addresses (LAN, `localhost`, Tailscale `100.64.0.0/10`, `*.ts.net`); everything else must be https. iOS App Transport
Security additionally allows plain http only to IP addresses and local names, so use https for `*.ts.net` names.
One function, `Endpoint.parse`, validates and normalises every address (pairing screen, Settings, saved list).

**Settings, Server** shows the current base URL and lets you edit it, and **Saved addresses** keeps a named list
(Tailscale, ngrok, LAN...): add, edit, delete, **Test connection** (`GET /api/session`: paired / not paired / unreachable)
and a one-tap switch. Switching moves the session socket, terminals, cameras and uploads to the new address without
pairing again when the same Jarvis server accepts the token; if the new address says "not paired", the pairing screen
opens for it ("Back to the connected address" returns). If the current address keeps failing, the home screen offers
**Edit address** (ngrok free URLs change on every restart).

Every request and WebSocket sends `Origin` = `<scheme>://<Host of the current address>` (the server refuses anything else),
a non-browser `User-Agent`, and `ngrok-skip-browser-warning: 1`, so ngrok's free-plan warning page does not break API calls.
An HTML answer where JSON is expected is reported as "an ngrok warning page or the wrong URL".

**Keychain:** one device token **per saved address** (`device-token.<address id>`); the address list itself (names,
URLs, no secrets) is in UserDefaults. The token belongs to the Jarvis server, so on a switch the target's own token is tried
first, then the current token; the first one the server calls paired is stored for the new address. Deleting an address
deletes only its token copy; "Forget this phone" and a revoked device remove the tokens of all addresses. The old
single-address storage is migrated automatically on first launch.

## What the app does with permissions

| Permission | When it is asked | If it is refused |
|---|---|---|
| Microphone | when the call starts for the first time | the Home screen explains and shows *Open Settings*; the chat, terminals, cameras and files keep working; coming back from Settings starts the call by itself |
| Camera | only when you tap *Take photo* | an explanation with *Open Settings* (or "restricted" when Screen Time forbids it) |
| Photo library | never needed: the system photo picker runs out of process | saving a snapshot to Photos asks for add-only access and explains a refusal |
| Local network | the system asks the first time the app talks to a LAN address | Tailscale / internet addresses do not need it |
| Notifications | not requested yet (structured in `SystemPermissions`, shown as "not used yet") | |

## Server side

Nothing to change. The app uses `POST /api/pair`, `/ws/session`, `/ws/terminal/{id}`, `/ws/camera/{id}` and the REST
routes listed in `docs/protocol.md`, always with the `jarvis_device` cookie and an `Origin` equal to the `Host`.
