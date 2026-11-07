//
//  AwayLock.swift
//  MacMate
//
//  Optionally locks the Mac when the phone leaves: half a minute after a
//  paired phone disconnects, if it hasn't come back. A phone switching
//  networks reconnects well within that, and when the Mac itself lost its
//  network the phone didn't go anywhere, so neither locks.
//

import Foundation
import Network

@MainActor
final class AwayLock {
    static let shared = AwayLock()

    /// Settings › General › "Lock this Mac when your phone leaves". Off by default.
    static let settingKey = "macmate_lock_when_phone_leaves"
    static let legacySettingKey = "tether_lock_when_phone_leaves"
    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.settingKey) as? Bool
            ?? UserDefaults.standard.bool(forKey: Self.legacySettingKey)
    }
    static let grace: TimeInterval = 30

    private var pending: [String: Task<Void, Never>] = [:]
    private let pathMonitor = NWPathMonitor()
    /// When the Mac's own network last changed.
    private var networkChangedAt = Date.distantPast

    private init() {
        pathMonitor.pathUpdateHandler = { _ in
            Task { @MainActor in AwayLock.shared.networkChangedAt = .now }
        }
        pathMonitor.start(queue: .main)
    }

    func phoneConnected(_ deviceId: String) {
        pending.removeValue(forKey: deviceId)?.cancel()
    }

    func phoneDisconnected(_ deviceId: String, name: String) {
        guard isEnabled else { return }
        pending[deviceId]?.cancel()
        let disconnectedAt = Date.now
        pending[deviceId] = Task {
            try? await Task.sleep(for: .seconds(Self.grace))
            guard !Task.isCancelled else { return }
            pending[deviceId] = nil
            guard isEnabled, MacMateService.shared.connection(for: deviceId) == nil else { return }
            // The Mac changed networks around then: every phone dropped, none left.
            guard networkChangedAt < disconnectedAt.addingTimeInterval(-5) else {
                MacMateLog("[AwayLock] \(name) disconnected while this Mac changed networks; not locking")
                return
            }
            MacMateLog("[AwayLock] \(name) left; locking this Mac")
            Self.lockScreen()
        }
    }

    /// The same lock as the menu bar's Lock Screen.
    private static func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            MacMateLog("[AwayLock] Locking isn't available on this macOS")
            return
        }
        unsafeBitCast(symbol, to: Lock.self)()
    }
}
