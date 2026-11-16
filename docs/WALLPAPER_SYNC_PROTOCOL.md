# PocketLink — `pocketlink.wallpaper` Protocol Contract

**Status:** Draft (v1)  
**Scope:** PocketLink Android only. macmate (macOS companion, separate repo) is the peer that sends this packet.

## 1. Purpose

Allow macmate to push the MacBook's desktop wallpaper to PocketLink so the Android app can render the real wallpaper in `MacDesktopPreview`. v1 is push-only (macmate → Android). There is no pull/`wallpaper.request` packet in v1.

## 2. Packet type

- Type string: `pocketlink.wallpaper`
- Direction: macmate → Android (outgoing on macmate, incoming on Android)
- Transport: KDE Connect Protocol v8 `NetworkPacket` over the existing TLS link, using the binary `payload` stream (not base64 in the JSON body).

## 3. Packet body (JSON)

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `mimeType` | String | Yes | Hint only. Android MUST validate by content, not trust this field. Expected: `image/jpeg` or `image/png`. |
| `width` | Int | Yes | Hint only. Android MUST use decoded bounds, not this field. |
| `height` | Int | Yes | Hint only. Android MUST use decoded bounds, not this field. |
| `sha256` | String | Yes | SHA-256 hex of the image bytes. Android uses this for dedupe short-circuit and post-write verification. |
| `schemaVersion` | Int | Yes | Integer schema version. v1 = `1`. Android ignores unknown future versions gracefully. |

Body fields are hints. Android never decodes based on `mimeType`/`width`/`height` alone; it sniffs the real format and uses decoded bounds.

## 4. Payload (binary stream)

- `NetworkPacket.payload` carries the raw image bytes as an `InputStream` with a declared `payloadSize`.
- Android streams `payload.inputStream` directly to a temp file on the IO dispatcher — no full-image buffering in memory.
- `payloadSize` may be `-1` or incorrect; Android enforces its own hard byte cap independently.

## 5. Android-side limits (hard caps, enforced regardless of macmate claims)

| Limit | Value |
|-------|-------|
| Max transfer bytes | 8 MB |
| Max image side (width or height) | 4096 px |
| Max total pixels | 16 MP |
| Accepted formats | JPEG, PNG (decoded by content sniffing) |

Reject the packet if any limit is exceeded, *before* a full decode where possible (bounds-only decode first).

## 6. Receive flow (Android `WallpaperPlugin.onPacketReceived`)

1. **Hash short-circuit:** If body `sha256` matches the cached hash for this device, drop the packet without reading the payload.
2. **Stream copy:** Copy `payload.inputStream` to a temp file on an IO dispatcher, serialized per device, computing SHA-256 via `DigestInputStream`.
3. **Close:** Always close the `InputStream`, including when dropping/rejecting the packet.
4. **Content validation:** Sniff the real image format and check decoded bounds against the limits (step 5). Discard on mismatch/oversize.
5. **Hash verification:** Compare computed SHA-256 to the claimed `sha256`; discard on mismatch.
6. **Atomic rename:** Rename temp file → `wallpaper.img` in `noBackupFilesDir/wallpapers/<sanitizedDeviceId>/`.
7. **Sidecar:** Write `wallpaper.meta` JSON (`sha256`, `mimeType`, `width`, `height`, `lastModified`) into the same directory *after* the image is in place.
8. **Dedupe:** Emit a new `WallpaperInfo` only when the hash changed; otherwise no-op.
9. **State:** Expose via `WallpaperRepository` per-device `StateFlow<WallpaperInfo>` (file path + version hash). Never expose a `Bitmap`.

## 7. Cache lifecycle

- **Store:** On successful receive, as above.
- **Delete on unpair:** `WallpaperRepository.deleteDevice(deviceId)` called directly from the unpair path (where `callback.unpaired` is handled), not solely via `Plugin.onDeviceUnpaired`, because stored capabilities may be stale and the plugin may not be loaded when offline.
- **Delete on disable:** `WallpaperRepository.deleteDevice(deviceId)` called from `Device.setPluginEnabled()` when disabling `WallpaperPlugin`. Not in `onDestroy` (plugins are destroyed/recreated on disconnect/reload, which would break `AvailableOffline`).
- **Legacy:** Ignore/delete the old `mac_wallpaper.png` previously read from `cacheDir`/`filesDir`.
- **Rehydration:** On plugin load, `WallpaperRepository` rehydrates `WallpaperInfo` from disk (image + sidecar). If sidecar is missing, recompute hash/mime on first read.

## 8. Capability advertisement

- Android `WallpaperPlugin.supportedPacketTypes = ["pocketlink.wallpaper"]` → advertises `incomingCapabilities` containing `pocketlink.wallpaper`.
- macmate must advertise `outgoingCapabilities` containing `pocketlink.wallpaper` for Android to load `WallpaperPlugin` (capability intersection in `Device.kt` `pluginsForCapabilities`).
- Stored capabilities for already-paired Macs can be stale; the next `kdeconnect.identity` exchange updates them and triggers a plugin reload.
- A user-disabled `WallpaperPlugin` still advertises capability, so macmate may push packets Android drops; macmate should throttle pushes.
- Packets only reach plugins for paired, trusted devices (existing behavior).

## 9. macmate responsibilities (OUT OF REPO — precondition)

- Capture main-display wallpaper via `NSWorkspace.desktopImageURL(for:)`. Dynamic/aerial/video wallpapers have no static file; macmate skips or falls back.
- Downscale + re-encode (JPEG 80–85%), compute SHA-256, send only JPEG or PNG.
- Send over the TLS payload socket; check macOS firewall prompt for inbound payload connections.
- Advertise outgoing `pocketlink.wallpaper`. Send on connect, on change, with throttling.
- PocketLink works and shows `NotSupported`/`Waiting` without macmate.

## 10. UI states (PocketLink `DesktopPreviewState`)

| State | Meaning |
|-------|---------|
| `NotApplicable` | Remote has no wallpaper capability |
| `NotSupported` | Capability present but plugin unavailable/disabled on remote side |
| `Disabled` | User toggled wallpaper sync off on Android (shows CTA to enable) |
| `Waiting` | Capable, nothing received yet |
| `Available` | Cached image present, device connected |
| `AvailableOffline` | Cached image present, device disconnected |

## 11. Security & privacy

- Never log image data or file contents.
- Store under `noBackupFilesDir` (excluded from Android backups).
- Delete on unpair and on user disable.
- Default toggle: off (user opt-in).
- macmate should have its own opt-in (documented as a macmate requirement).

## 12. Open items

- Confirm macmate build advertises `pocketlink.wallpaper` before end-to-end physical testing.
- Debug-only fake-sender harness for phone-side development without macmate.
