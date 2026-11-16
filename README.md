<p align="center">
  <img src="MacMate/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="112" height="112" alt="MacMate app icon" />
</p>

<h1 align="center">MacMate</h1>

<p align="center">
  <strong>Your Mac and Android, in sync.</strong><br />
  A lightweight, native macOS companion for Android that seamlessly integrates notifications, text messages, calls, file transfers, clipboard synchronization, and media controls.
</p>

<p align="center">
  <a href="https://github.com/sheihan-javaid/MacMate/releases/latest"><img src="https://img.shields.io/github/v/release/sheihan-javaid/MacMate?style=flat-square&color=2e6bf0&label=download" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square" alt="macOS 15 or later" />
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-supported-black?style=flat-square" alt="Apple Silicon and Intel" />
  <img src="https://img.shields.io/badge/license-GPL--2.0-3b8f4a?style=flat-square" alt="GPL-2.0" />
</p>

<p align="center">
  <img src="docs/images/hero.jpg" alt="MacMate main window and menu bar popover on a Mac desktop" />
</p>

---

## Overview

**MacMate** is a fully native macOS client built for the **KDE Connect** ecosystem. It bridges your Android phone and Mac seamlessly without third-party cloud accounts, subscription fees, or invasive telemetry. Everything communicates directly over your local Wi-Fi network or a private Tailscale tunnel using peer-to-peer TLS encryption.

Unlike bulky cross-platform ports that package massive runtime layers, MacMate is written purely in Swift and SwiftUI. It uses standard Apple system components and materials, starts instantly, consumes minimal memory, and lives unobtrusively in your menu bar.

---

## Key Features & Capabilities

### 🔔 Notifications & Quick Reply
- **System Notification Center:** Incoming phone notifications appear as native macOS alerts and banners.
- **Inline Replies:** Reply directly to SMS, WhatsApp, Telegram, Signal, and other supported messaging apps from the notification banner.
- **Two-Way Dismissal:** Dismissing an alert on your Mac clears it from your phone, and vice versa.
- **Verification Code Actions:** Automatic detection of one-time sign-in codes with a dedicated "Copy Code" action in the banner and menu bar.
- **Notification Attachments:** Contact avatars and media pictures sent by phone apps appear directly in notification banners (see [notification images documentation](docs/notification-images.md)).
- **WhatsApp Suppression:** Avoids duplicate banner alerts when native WhatsApp for Mac is actively running, routing clicks to open the desktop app directly.

### 💬 SMS Conversations
- **Full Thread History:** View and navigate conversation threads in the Messages pane with contact names and photos synchronized from your device.
- **Compose & Send:** Start new threads or reply to existing ones directly from macOS.
- **Dual-SIM Support:** Choose which SIM card to send text messages from on multi-SIM phones and customize SIM display labels.

### 📞 Call Management
- **Incoming Call Alerts:** Displays a persistent floating notification card with the caller's name and photo.
- **Silence Ringer:** Silence your phone's ringer with a single click from your Mac.
- **Active Call Timer:** Transforms into an active call status indicator while the call is ongoing.
- **Media Pausing:** Automatically pauses local Mac audio and video playback when a call arrives, and resumes playback when the call ends.
*(Note: Answering or speaking on calls from macOS is not supported by the underlying KDE Connect protocol; call audio remains on the phone.)*

### 📁 File Transfers & Phone File Browsing
- **Drag & Drop Sharing:** Drop files onto the MacMate menu bar popover or main window to send them immediately to your device.
- **macOS Share Extension:** Use **Share › MacMate** from Finder, Photos, Safari, and other macOS apps to send files or links.
- **Finder Drive Integration:** When connected, your phone's storage volumes can be mounted directly in Finder as a local drive using a lightweight loopback NFS server backed by SFTP or ADB. Open files and stream videos on demand without downloading entire folders upfront.
- **Incoming Transfers:** Files sent from your phone are securely streamed to your `~/Downloads` folder with download progress indicators.

### 📋 Clipboard Synchronization
- **Bidirectional Sync:** Copy plain text on your Mac to immediately paste it on Android, and receive text copied on Android onto your Mac clipboard.
*(Note: Android 10+ restricts background clipboard reads; Android sends clipboard updates when opened or when tapping KDE Connect's quick tile or "Send Clipboard" action.)*

### 🎵 Media Controls & Remote Actions
- **Phone Playback Control:** View currently playing phone media (track title, artist, album artwork) and adjust media volume, play, pause, or skip tracks.
- **Mac Media Control from Android:** Control media playing on your Mac (Apple Music, Spotify, browsers) from the KDE Connect app on your phone.
- **Find My Phone:** Trigger your phone to ring at maximum volume to locate it quickly.
- **Ring Mac:** Trigger an audible alert on your Mac from your phone.
- **Battery & Device Status:** Monitor your phone's battery percentage, charging state, and cellular signal in the menu bar. Your Mac's battery state is also reported back to Android.

### 🖱️ Remote Input & Presentations
- **Trackpad & Keyboard:** Use your phone screen as a wireless trackpad (pointer movement, tap-to-click, two-finger scrolling) and software keyboard for your Mac.
- **Presentation Remote:** Advance presentation slides and project an interactive laser pointer onto your Mac screen during talks.
*(Requires macOS Accessibility permissions.)*

### ⚡ Custom Shell Commands
- Configure custom shell scripts or trigger macOS Shortcuts directly from the KDE Connect interface on your phone.
- Optional automatic Mac screen lock when your phone disconnects or goes out of range.

### 📱 Screen Mirroring (via scrcpy & ADB)
- **High-Framerate Display Launcher:** MacMate includes a dedicated Screen Mirroring pane with built-in path diagnostics for `adb` and `scrcpy`.
- **Display Engine:** Rather than attempting a fragile, high-latency custom video capture protocol, MacMate launches the open-source **[scrcpy](https://github.com/Genymobile/scrcpy)** display engine over USB or wireless ADB.
- **Prerequisites:** Requires `scrcpy` and `android-platform-tools` installed on your Mac (e.g., via Homebrew) and USB/Wireless Debugging enabled on your Android phone.

---

## System Requirements

- **macOS Version:** macOS 15.0 Sequoia or later.
- **Hardware Architecture:** Universal binary with native support for both **Apple Silicon** (M1/M2/M3/M4) and **Intel** 64-bit processors.
- **Android Device:** Any Android phone or tablet running the official **KDE Connect** application (available on [Google Play](https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp) or [F-Droid](https://f-droid.org/packages/org.kde.kdeconnect_tp/)). No custom ROM or root access required.

---

## Network Discovery & Secure Pairing

1. **Automatic Local Discovery:** MacMate listens on UDP port `1716` and broadcasts UDP discovery packets. It also announces and resolves `_kdeconnect._udp` via Bonjour (mDNS) to discover devices on networks that restrict UDP broadcast traffic.
2. **Encrypted Transport:** Once a device is detected, a TCP connection is established on ports `1716`–`1764` and immediately upgraded to TLS using Apple's Security framework.
3. **Mutual Certificate Pinning:** Both sides present self-signed ECDSA certificates on the NIST P-256 curve (`prime256v1`, signed with SHA-256) during the TLS handshake. When you pair, MacMate saves the phone's certificate SHA-256 fingerprint in its preferences (`com.subhashh.MacMate`, key `macmate_paired_devices`). A later connection from a device that presents a different certificate is treated as unpaired: nothing it sends other than a pairing request is accepted.
4. **Tailscale VPN Support:** If both your Mac and phone run [Tailscale](https://tailscale.com) under the same tailnet account, MacMate queries the local Tailscale socket to automatically discover your phone even across cellular data or remote networks. You can also manually connect to any device by entering its IP address or Tailscale MagicDNS name (`device.tailnet.ts.net`).

---

## Installation

### Method 1: Homebrew (Recommended)
Installing via Homebrew automatically manages installation and prevents initial Gatekeeper blockage:

```bash
brew install --cask sheihan-javaid/macmate/macmate
```

### Method 2: Manual Download (Disk Image)
Download the latest DMG corresponding to your Mac's hardware from the **[Releases](https://github.com/sheihan-javaid/MacMate/releases/latest)** page:

| Architecture | Package |
| :--- | :--- |
| **Apple Silicon (M1/M2/M3/M4)** | `MacMate-<version>-AppleSilicon.dmg` |
| **Intel (x86_64)** | `MacMate-<version>-Intel.dmg` |

1. Open the downloaded `.dmg` file.
2. Drag **MacMate.app** into your `/Applications` directory.
3. Launch MacMate from Applications or Spotlight.

### Bypassing Gatekeeper on Manual Builds
MacMate is open-source software and is not signed with an Apple Developer ID certificate. On first launch, macOS may report that the app cannot be opened because Apple cannot check it for malicious software.

To authorize execution:
1. Open **System Settings › Privacy & Security**.
2. Scroll to the **Security** section and click **Open Anyway**.
3. Alternatively, remove the quarantine attribute via Terminal:
   ```bash
   xattr -cr /Applications/MacMate.app
   ```

---

## Required Permissions & Dependencies

| Feature | macOS Permission / Dependency | Purpose |
| :--- | :--- | :--- |
| **Local Discovery** | Local Network | Enables mDNS and UDP broadcasting on Wi-Fi |
| **Notifications** | Notifications | Delivers notifications and allows inline replies |
| **Remote Input / Laser** | Accessibility | Simulates mouse movement, clicks, and keystrokes |
| **Media Player Control** | Accessibility / `/usr/bin/perl` | Interfaces with macOS Now Playing via `MediaRemoteAdapter` |
| **Screen Mirroring** | `adb` & `scrcpy` (Homebrew) | External tools for launching wireless/wired screen mirroring |

To install external screen mirroring dependencies:
```bash
brew install scrcpy android-platform-tools
```

---

## Building from Source

### Prerequisites
- macOS 15.0 or later
- Xcode 16.0 or later (Swift 6.2 toolchain)
- Command Line Tools: `xcode-select --install`

### Build Steps

1. **Clone the repository:**
   ```bash
   git clone https://github.com/sheihan-javaid/MacMate.git
   cd MacMate
   ```

2. **Run tests:**
   ```bash
   xcodebuild test -project MacMate.xcodeproj -scheme MacMate -destination "platform=macOS"
   ```

3. **Build the Release application:**
   ```bash
   xcodebuild -project MacMate.xcodeproj -scheme MacMate -configuration Release -derivedDataPath build build
   ```
   The compiled application bundle will be created at:
   `build/Build/Products/Release/MacMate.app`

4. **Package release DMGs and ZIPs:**
   ```bash
   scripts/release.sh
   ```

---

## Project Structure

```
MacMate/
├── MacMate/                         # Main macOS application source
│   ├── Assets.xcassets/             # App icons, status symbols, and images
│   ├── Files/                       # File browsing, loopback NFS server & SFTP client
│   │   ├── NFS/                     # Custom RPC / NFSv3 implementation and mount coordinator
│   │   └── SSH/                     # CryptoKit-backed SSH/SFTP client for remote file access
│   ├── Network/                     # Networking, discovery, and encryption
│   │   ├── DeviceConnection.swift   # TLS socket transport & KDE Connect packet engine
│   │   ├── MDNSDiscovery.swift      # Bonjour mDNS discovery listener & advertiser
│   │   ├── PayloadTransfer.swift    # TLS binary payload upload and download handlers
│   │   ├── TailscaleDiscovery.swift # Local tailnet device resolution
│   │   └── UDPDiscoveryService.swift# Broadcast UDP packet discovery engine
│   ├── Plugins/                     # Protocol plugins (battery, clipboard, media, notifications, etc.)
│   ├── Resources/                   # MediaRemote perl adapter & helper assets
│   ├── Security/                    # EC (P-256) key generation, certificate identity, trust store
│   ├── Updates/                     # In-app update checker and signature verification
│   ├── Utils/                       # Logging, process coordination, and safe path utilities
│   ├── ViewModels/                  # Observable application state models
│   └── Views/                       # SwiftUI views (Menu bar, Settings, Tabs, Screen Mirroring)
├── MacMateShare/                    # macOS Share Extension (Share › MacMate)
├── MacMateTests/                    # Unit tests and protocol test suites
├── MacMateUITests/                  # Automated UI testing suite
├── Vendor/                          # Bundled third-party adapters (MediaRemoteAdapter)
├── docs/                            # Deep-dive architecture and design documentation
└── scripts/                         # Build, release, and update automation scripts
```

---

## Security & Privacy Information

- **Local Network Isolation:** All communication between your phone and your Mac remains entirely on your local network (or private encrypted Tailscale network). MacMate runs no cloud servers, requires no user accounts, and contains no analytics, diagnostic beacons, or telemetry trackers.
- **Cryptographic Identification:** On first launch MacMate generates a NIST P-256 (`prime256v1`) key and a self-signed ECDSA-with-SHA-256 certificate, valid for 10 years, using the system `openssl`. They are kept in `~/Library/Application Support/MacMate/` (folder `0700`, files `0600`) as `key.pem`, `certificate.pem` and an `identity.p12` bundle whose random passphrase is stored beside it in `identity.pass`. Because that passphrase sits next to the bundle, the real protection is the file permissions and disk encryption (FileVault). Nothing is stored in the keychain, and the keys never leave your Mac. See [docs/identity-backup.md](docs/identity-backup.md) to back them up and restore them safely.
- **Certificate Pinning:** Only a device whose certificate matches the SHA-256 fingerprint saved at pairing is treated as paired. Others may connect only to request pairing; everything else they send is dropped, and file transfers are refused if the certificate differs. TLS versions and cipher suites are chosen by macOS; MacMate does not override them.
- **Updater Verification:** Software updates are signed with a dedicated release certificate. Before replacing an installed copy, the update installer verifies bundle integrity, code signature provenance, and matching bundle identifiers.
- **Independent Storage:** MacMate keeps its own preferences (`com.subhashh.MacMate`), identity and files (`~/Library/Application Support/MacMate`, `~/Library/Caches/MacMate*`). It never reads, imports, changes or deletes data from Tether, KDE Connect or any other application, so a first launch starts clean and every phone is paired afresh.

---

## Known Limitations

- **Call Audio:** macOS cannot be used as a Bluetooth or VoIP speakerphone for cellular calls via KDE Connect; call audio remains on the Android device.
- **Answering Calls:** The KDE Connect Android protocol only allows muting/silencing incoming phone calls, not answering or declining them.
- **Android App Icons in Banners:** Android provides notification attachments (photos, avatars) and small icons, but not raw application bundle icons. Furthermore, macOS Notification Center always displays the host app icon (MacMate) in the alert banner header.
- **Android Background Clipboard:** On Android 10 and newer, apps in the background cannot read the system clipboard. Copying on your Mac reaches your phone automatically; sending clipboard contents from Android requires opening KDE Connect or using its quick-settings tile.
- **Screen Mirroring Architecture:** Screen mirroring requires external `adb` and `scrcpy` binaries; MacMate coordinates the environment, manages device discovery, and launches the display session.

---

## License & Attribution

- **License:** MacMate is free, open-source software licensed under the **GNU General Public License v2.0 (GPL-2.0)**. See [LICENSE](LICENSE) for details.
- **Upstream Project Attribution:** MacMate is based upon and continues the work of the **Tether** project by Subhash. It maintains full protocol compatibility with the upstream KDE Connect project.
- **MediaRemoteAdapter:** Includes `mediaremote-adapter` by Jonas van den Berg, licensed under the **BSD 3-Clause License** (see [Vendor/MediaRemoteAdapter/LICENSE](Vendor/MediaRemoteAdapter/LICENSE)).
- **Disclaimer:** MacMate is an independent open-source project and is not affiliated with, endorsed by, or part of the KDE Project.
