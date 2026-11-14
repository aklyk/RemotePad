<p align="center">
  <img src="Resources/RemotePad-Icon.png" alt="RemotePad app icon" width="120" />
</p>

<h1 align="center">RemotePad</h1>
<p align="center"><strong>Your iPhone. Your Mac’s trackpad.</strong></p>
<p align="center">A native iPhone trackpad and Mac companion with encrypted local connections.</p>
<p align="center">
  <a href="LICENSE">MIT licensed</a> · iOS 16+ · macOS 13+ · SwiftUI
</p>

[![Build and validate](https://github.com/nacimoualla/RemotePad/actions/workflows/build.yml/badge.svg)](https://github.com/nacimoualla/RemotePad/actions/workflows/build.yml)

RemotePad turns your iPhone’s screen into a wireless trackpad for your Mac. Move the pointer, click, scroll, drag, zoom, and navigate desktop spaces from the couch or across your desk. No accounts, cloud backend, or third-party app dependencies.

> **Source release:** build the two apps using the instructions below. There is no App Store or notarized binary release yet. Moving the phone through the air does not move the pointer; slide your finger on its screen.

## Features

- **Multi-touch controls:** pointer movement, clicks, scrolling, long-press dragging, pinch zoom, and three-finger navigation.
- **Personal preferences:** adjustable pointer speed, natural or reversed scrolling, and optional gesture haptics, saved on your iPhone.
- **Visible connection health:** the iPhone warns when Mac Accessibility access is blocked; the Mac displays received-command counts.
- **Encrypted pairing:** nearby discovery with Apple’s Multipeer Connectivity, encryption required, and approval on the Mac for the first pairing.
- **Control on your terms:** one controller at a time, disconnect and pause controls, remembered-pairing revocation, and automatic mouse-button release after disconnect or six seconds without incoming packets.
- **Native apps:** SwiftUI interfaces, UIKit gesture recognition, Core Graphics input, and matching app icons.

## Get started

### Requirements

| | Minimum |
| --- | --- |
| iPhone | iOS 16 |
| Mac | macOS 13 |
| Building both apps | Xcode 15+ with the iOS SDK |
| Signing the iPhone app | An Apple Account configured in Xcode |
| Network | Start with both devices on the same Wi-Fi |

A free Apple Account can be used for personal development. Apple may require Developer Mode and developer-profile trust on the iPhone. Development provisioning expires and may require rebuilding; follow the expiry shown by Xcode.

### 1. Build and run the Mac companion

```sh
git clone https://github.com/nacimoualla/RemotePad.git
cd RemotePad
./scripts/build-mac.sh
open "build/RemotePad Mac.app"
```

You can also open `RemotePad.xcodeproj` and run the **RemotePadMac** scheme.

In the companion, click **Enable Accessibility Access**, then enable **RemotePad Mac** in **System Settings → Privacy & Security → Accessibility**. Allow Local Network access and incoming connections if macOS asks. Keep the companion open in your logged-in desktop session.

The build script uses an available Apple Development signing identity, or ad hoc signing when none is available. It remembers that choice in the ignored `.remotepad-signing-identity` file so later builds do not silently switch identities. Override it explicitly with:

```sh
REMOTEPAD_SIGN_IDENTITY="Apple Development: Your Name (IDENTIFIER)" ./scripts/build-mac.sh
```

Ad hoc rebuilds and changes to an app’s signing identity can require granting Accessibility again. Use the same app location and signing identity between updates. This local development build is not notarized for distribution.

### 2. Install the iPhone app

1. Open `RemotePad.xcodeproj` in Xcode and select the **RemotePad** scheme.
2. Select the RemotePad target’s **Signing & Capabilities** tab. Choose your development team and replace `com.example.RemotePad` with your own unique bundle identifier.
3. Connect your iPhone to the Mac. Trust the computer and enable Developer Mode if requested.
4. Select the iPhone as the run destination, then click **Run**.
5. Allow **Local Network** access when RemotePad asks.

If iOS reports an untrusted developer, open **Settings → General → VPN & Device Management**, select your development profile, and complete the trust steps. See [Apple’s device-running guide](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).

### 3. Pair and control

Open both apps, select your Mac on the iPhone, and click **Allow Connection** in the Mac companion. Both devices should be awake on the same Wi-Fi. Approve only a connection you just initiated: device display names are not verified identities.

Once connected, slide a finger across the large trackpad area. The iPhone keeps its screen awake while connected. Leaving the app disconnects it; open it again to reconnect automatically after the first pairing.

## Automatic reconnection

Approve your iPhone once in the Mac companion. The apps save the pairing credential in each device’s Keychain and remember their peer identities. **Automatically reconnect** is enabled by default in the iPhone’s connection settings. When you reopen RemotePad or return to it, it discovers the remembered Mac and reconnects without another approval prompt. Failed automatic attempts use a short backoff and stop after three attempts; tap the Mac to approve pairing again if credentials were revoked.

**iOS background limit:** [Multipeer Connectivity disconnects sessions in the background](https://developer.apple.com/documentation/multipeerconnectivity). RemotePad cannot stay connected indefinitely while the iPhone app is closed or force-quit. It releases held input on leaving the foreground, remembers the pairing, and reconnects when you return. It does not use audio, location, or other unrelated background modes to bypass iOS restrictions.

On the Mac, closing the window keeps the companion running in the **menu bar**. Choose **Open RemotePad** there to reopen the window. Quitting the Mac app stops discovery and connections until it is launched again.

- **Forget this Mac** on iPhone removes its stored credential.
- **Forget All** on Mac revokes all remembered iPhones; they need fresh approval.
- **Disconnect** on iPhone stops automatic retries until you return to the app or connect manually.
- **Disconnect & Pause** on Mac pauses incoming connections until **Allow connections** is enabled again.

Returning phones must answer a fresh HMAC-SHA256 challenge before the Mac accepts any mouse commands. Secrets are delivered over the approved encrypted session, stored in Keychain, and never put in Bonjour advertisements or invitation contexts. The Mac disconnects a provisional session if authentication does not complete within five seconds.

## Gesture guide

| Gesture or control | Result |
| --- | --- |
| One-finger swipe | Move the pointer |
| Tap / double-tap | Click / double-click |
| Two-finger tap | Right-click |
| Two-finger swipe | Scroll horizontally or vertically |
| Hold for 0.4 seconds, move, then lift | Drag and release |
| Drag button → swipe → Release | Keep a drag held across several swipes |
| Pinch out / in | Zoom in / out |
| Two-finger double-tap | Reset zoom |
| Three-finger swipe left / right | Next / previous desktop space |
| Three-finger swipe up / down | Mission Control / application windows |
| Sliders icon or Gesture guide | Preferences and gesture reference |

**Compatibility:** zoom sends Command-plus/minus/zero to the active Mac app. The app must support those shortcuts. Space and window navigation reads your configured Mission Control shortcuts, including custom modifier keys; enable these in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control** if needed. Space switching requires another desktop space. Mac shortcuts and keyboard layouts can affect these actions.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| No Mac appears | Keep the companion open, allow Local Network access on both devices, and tap Refresh on the phone. |
| Discovery fails on office or guest Wi-Fi | Guest isolation, firewalls, and VPNs can block peer discovery. Try a regular home Wi-Fi network. |
| Connected, but the pointer does not move | Check the phone’s permission warning and the Mac’s received-command counter. Enable Accessibility for the exact Mac app you launched. |
| Accessibility is on, but RemotePad says it is blocked | Remove RemotePad Mac from the Accessibility list, add the current `.app` again using **+**, enable it, then quit and reopen the companion. This can happen after signing changes. |
| Pairing expires | Select the Mac again and approve within 25 seconds. |
| Connection drops when switching iPhone apps | Expected: iOS disconnects peer sessions in the background. Return to RemotePad to reconnect automatically. |
| Zoom or space gestures do nothing | Focus a compatible Mac app and check its keyboard shortcuts. |
| App installs but iOS blocks opening it | Complete developer-profile trust and Developer Mode setup on the iPhone. |

The Mac companion only controls your current desktop session. Login screens and protected system interfaces are outside its scope.

## Development

```sh
# Validate command decoding, permission feedback, pairing authentication, and gesture calculations.
swift run ProtocolChecks

# Check click buttons and shortcut modifier cleanup without posting any input.
./scripts/check-mouse-driver.sh

# Build, package, sign, and verify the Mac companion.
./scripts/build-mac.sh

# Build iPhone source without a development signing identity.
xcodebuild -project RemotePad.xcodeproj -scheme RemotePad \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Simulator CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions runs the protocol checks and builds both apps on macOS. Real-device discovery, multi-touch feel, permission transitions, and multi-monitor behavior still need hands-on testing; a passing build does not verify those interactions.

### Project structure

```text
Sources/
  iOS/        iPhone UI, gestures, peer discovery, connection status
  Mac/        Pairing UI, permission checks, command receiver, input events
  Shared/     Bounded command/status protocol and gesture calculations
Resources/    App icons, asset catalog, and permission declarations
Tests/        Standalone protocol and gesture checks
scripts/      Mac packaging and vector icon generation
```

```mermaid
flowchart LR
  A[iPhone gestures] --> B[Validated commands]
  B -->|Encrypted MCSession| C[Mac receiver]
  C --> D[Core Graphics input]
  C -->|Permission status| A
```

Commands and status messages are bounded to 512 bytes. The receiver rejects malformed messages, unsupported actions, nonfinite coordinates, and excessive movement. Heartbeats maintain the drag safety timeout and refresh permission feedback. There is no telemetry or analytics service in this project.

To regenerate the vector-drawn icons:

```sh
swift scripts/generate-icons.swift
iconutil -c icns Resources/RemotePad.iconset -o Resources/RemotePad.icns
```

## Contributing

Bug reports and pull requests are welcome. Include the iOS/macOS versions, what each app shows for connection and Accessibility status, and steps to reproduce. Do not attach signing certificates, provisioning profiles, or account credentials. For a change, run the checks and both builds above, and describe any hardware testing you performed.

## License

[MIT](LICENSE) © 2026 Nacim Oualla.
