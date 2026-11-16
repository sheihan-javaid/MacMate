//
//  WallpaperSyncService.swift
//  MacMate
//
//  Mac-side driver for the PocketLink `pocketlink.wallpaper` push.
//  Sends the main-display wallpaper to paired phones over the existing
//  TLS payload socket, reusing `PayloadUploader` (the same path SharePlugin
//  uses for file transfers).
//
//  Sends only when the user-opt-in setting is on, deduplicates by SHA-256,
//  throttles by a minimum interval, and logs only hash prefix, size, outcome.
//

import AppKit
import Foundation

/// Opt-in gate: wallpaper sharing is off by default and nothing is sent unless
/// the user turns it on.
public final class WallpaperSyncService: NSObject {
    public static let shared = WallpaperSyncService()

    /// Whether wallpaper sharing is enabled (the Settings toggle, default OFF).
    public var isEnabled: Bool { SettingsViewModel.shared.shareWallpaper }

    /// Dedupe-by-hash + min-interval throttle, shared so tests can inspect it.
    public let gatekeeper = WallpaperSendGatekeeper(minSendInterval: 60)

    private let sendQueue = DispatchQueue(label: "com.subhashh.macmate.wallpaper.send", qos: .userInitiated)
    private var pollTimer: DispatchSourceTimer?
    /// Cheap source-file attribute pre-filter used by the poller (single main screen).
    private var lastSourceAttributes: (size: Int64, modDate: Double)?
    private let attrLock = NSLock()

    private override init() {
        super.init()
        setupChangeObservers()
        // Not started here: MacMateService calls `start()` once it is running.
        // Reading the setting now would build SettingsViewModel, which needs
        // MacMateService, which is what is creating this object.
    }

    deinit {
        stopPollTimer()
    }

    // MARK: - Lifecycle

    /// Starts the change poller if sharing was already on at launch.
    public func start() {
        if isEnabled { startPollTimer() }
    }

    /// The Settings toggle changed: start or stop polling, and push right away
    /// when it was just turned on.
    public func enabledChanged() {
        if isEnabled {
            startPollTimer()
            sendToAllConnected()
        } else {
            stopPollTimer()
        }
    }

    // MARK: - Public triggers

    /// Send the wallpaper to one device once it is paired and the link is usable.
    public func requestSend(to deviceId: String, connection: DeviceConnection) {
        guard isEnabled else { return }
        // AppKit's screen and wallpaper APIs are main-thread only, so read the
        // file URL here and let the send queue do the decoding and uploading.
        let wallpaperURL = WallpaperPreparer.mainScreenWallpaperURL()
        sendQueue.async { [weak self] in
            self?.performSend(deviceId: deviceId, connection: connection, wallpaperURL: wallpaperURL)
        }
    }

    /// Send to every connected, paired device (wallpaper-change trigger).
    public func sendToAllConnected() {
        guard isEnabled else { return }
        for (deviceId, connection) in MacMateService.shared.connectedDevices
            where connection.pairState == .paired {
            requestSend(to: deviceId, connection: connection)
        }
    }

    /// Clear dedupe state for a device so it is re-offered once per (re)connection.
    /// Call whenever a device connects or reconnects; the phone's short-circuit
    /// is per-device and its cache may have been cleared while disconnected.
    public func clearDedupe(for deviceId: String) {
        gatekeeper.reset(deviceId: deviceId)
    }

    /// Periodic poll: cheap source-file attribute pre-filter, then push if changed.
    func tick() {
        guard isEnabled else { return }
        let current = attrLock.withLock { () -> (size: Int64, modDate: Double)? in
            guard let screen = NSScreen.screens.first,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64,
                  let mod = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
                lastSourceAttributes = nil
                return nil
            }
            return (size, mod)
        }
        guard let current else { return }
        let changed = attrLock.withLock { () -> Bool in
            if let prev = lastSourceAttributes, prev.size == current.size, prev.modDate == current.modDate {
                return false
            }
            lastSourceAttributes = current
            return true
        }
        guard changed else { return }
        sendToAllConnected()
    }

    // MARK: - Send (runs on sendQueue so the blocking payload upload never blocks the main thread)

    private nonisolated func performSend(deviceId: String, connection: DeviceConnection, wallpaperURL: URL?) {
        guard let wallpaperURL, let result = WallpaperPreparer.prepareFile(wallpaperURL) else {
            MacMateLog("[WallpaperSyncService] No wallpaper to send to \(deviceId)")
            return
        }
        let now = Date()
        guard gatekeeper.canSend(deviceId: deviceId, hash: result.sha256, now: now) else {
            MacMateLog("[WallpaperSyncService] Skipping wallpaper push to \(deviceId) (unchanged or throttled)")
            return
        }
        gatekeeper.recordAttempt(deviceId: deviceId, now: now)

        // Stage the exact bytes on disk so PayloadUploader can stream them.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let tempFile = caches.appendingPathComponent("com.subhashh.macmate.wallpaper-\(UUID().uuidString).jpg", isDirectory: false)
        do { try result.data.write(to: tempFile) } catch {
            MacMateLog("[WallpaperSyncService] Failed to stage wallpaper: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let semaphore = DispatchSemaphore(value: 0)

        PayloadUploader().start(
            fileURL: tempFile,
            expectedPeerFingerprint: connection.peerCertificateFingerprint,
            onReady: { offer in
                let packet = NetworkPacket(
                    type: "pocketlink.wallpaper",
                    body: [
                        "mimeType": AnyCodable(result.mimeType),
                        "width": AnyCodable(result.width),
                        "height": AnyCodable(result.height),
                        "sha256": AnyCodable(result.sha256),
                        "schemaVersion": AnyCodable(1)
                    ],
                    payloadSize: Int64(result.data.count),
                    payloadTransferInfo: ["port": AnyCodable(Int(offer.port))]
                )
                connection.send(packet: packet)
                MacMateLog("[WallpaperSyncService] Announced pocketlink.wallpaper to \(deviceId): \(result.mimeType) \(result.width)x\(result.height) \(result.data.count) bytes sha \(result.sha256.prefix(12))...")
            },
            onProgress: { _ in },
            onComplete: { [gatekeeper] res in
                if case .success = res {
                    // "Success" means the payload streamed in full and the peer's
                    // TLS close completed — the phone now holds the exact bytes
                    // whose sha256 is in the body. Record dedupe so we don't
                    // re-offer an unchanged wallpaper to this device.
                    gatekeeper.recordSuccess(deviceId: deviceId, hash: result.sha256, now: now)
                    MacMateLog("[WallpaperSyncService] Wallpaper push to \(deviceId) delivered: payload complete")
                } else {
                    // Peer declined / timed out (e.g. plugin disabled, unreachable).
                    // Benign outcome: no error surfaced, no retry loop, and
                    // PayloadUploader already released its listener port.
                    MacMateLog("[WallpaperSyncService] Wallpaper push to \(deviceId) ended without delivery: \(res)")
                }
                semaphore.signal()
            }
        )

        _ = semaphore.wait(timeout: .distantFuture)
    }

    // MARK: - Change notifications

    private func setupChangeObservers() {
        let center = NotificationCenter.default
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification] {
            center.addObserver(self, selector: #selector(screenChanged), name: name, object: nil)
        }
        // NSWorkspace posts its notifications on its own center, never on the
        // default one.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func screenChanged() {
        sendToAllConnected()
    }

    private func startPollTimer() {
        stopPollTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: .seconds(60))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopPollTimer() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}

/// Dedupe by SHA-256 (skip if unchanged since last successful send) plus a
/// minimum-interval throttle on send attempts (so a disabled phone plugin
/// isn't hammered with retries).
public nonisolated final class WallpaperSendGatekeeper: @unchecked Sendable {
    public let minSendInterval: TimeInterval

    private let lock = NSLock()
    /// Hash of the last successfully sent wallpaper per device.
    private var lastSentHash: [String: String] = [:]
    /// Time of the last send attempt per device (success or failure).
    private var lastAttemptTime: [String: Date] = [:]

    public init(minSendInterval: TimeInterval = 60) {
        self.minSendInterval = minSendInterval
    }

    /// `true` if a send should proceed: wallpaper changed and interval elapsed.
    public func canSend(deviceId: String, hash: String, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = lastSentHash[deviceId], last == hash { return false }
        if let lastTime = lastAttemptTime[deviceId], now.timeIntervalSince(lastTime) < minSendInterval { return false }
        return true
    }

    public func recordAttempt(deviceId: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        lastAttemptTime[deviceId] = now
    }

    public func recordSuccess(deviceId: String, hash: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        lastSentHash[deviceId] = hash
        lastAttemptTime[deviceId] = now
    }

    public func lastHash(for deviceId: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return lastSentHash[deviceId]
    }
    public func reset(deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        lastSentHash.removeValue(forKey: deviceId)
        lastAttemptTime.removeValue(forKey: deviceId)
    }
    public func resetAll() {
        lock.lock(); defer { lock.unlock() }
        lastSentHash.removeAll()
        lastAttemptTime.removeAll()
    }
}