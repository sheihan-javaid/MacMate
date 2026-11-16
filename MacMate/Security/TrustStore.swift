//
//  TrustStore.swift
//  MacMate
//

import Foundation
import Combine

public final class TrustStore: ObservableObject, @unchecked Sendable {
    public static let shared = TrustStore()

    @Published public private(set) var pairedDevices: [String: PairedDevice] = [:]

    static let userDefaultsKey = "macmate_paired_devices"
    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Tests pass their own `defaults` so they never touch the saved pairings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadDevices()
    }

    /// Build 1.2 shipped with the author's own phone pre-trusted on every install.
    /// It is removed on load so nobody trusts a device they never paired.
    private static let removedPreloadedDeviceIds: Set<String> = ["5bbcb3e152d34b9597997d39ca4587ce"]

    private func loadDevices() {
        let stored = decode(key: Self.userDefaultsKey) ?? []
        let kept = stored.filter { !Self.removedPreloadedDeviceIds.contains($0.deviceId) }

        self.pairedDevices = Dictionary(kept.map { ($0.deviceId, $0) }, uniquingKeysWith: { _, latest in latest })

        // Persist when a preloaded entry was dropped, and on first launch so the key exists.
        if kept.count != stored.count || defaults.data(forKey: Self.userDefaultsKey) == nil {
            saveDevices()
        }
    }

    private func decode(key: String) -> [PairedDevice]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            let list = try JSONDecoder().decode([PairedDevice].self, from: data)
            return list.isEmpty ? nil : list
        } catch {
            // Never silently treat unreadable pairings as "none": that would let
            // the next save overwrite them. Keep the raw bytes for recovery.
            MacMateLog("[TrustStore] Could not read \(key): \(error)")
            defaults.set(data, forKey: "\(key)_unreadable_backup")
            return nil
        }
    }

    private func saveDevices() {
        let list = Array(pairedDevices.values)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }

    public func isTrusted(deviceId: String) -> Bool {
        lock.withLock {
            pairedDevices[deviceId] != nil
        }
    }

    public func pairedDevice(for deviceId: String) -> PairedDevice? {
        lock.withLock {
            pairedDevices[deviceId]
        }
    }

    public func add(device: PairedDevice) {
        lock.withLock {
            self.pairedDevices[device.deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    /// Forgets a paired device. `reason` is logged so a lost pairing can always be traced.
    public func remove(deviceId: String, reason: String) {
        lock.withLock {
            let name = self.pairedDevices[deviceId]?.deviceName ?? "unknown"
            MacMateLog("[TrustStore] Removing \(name) (\(deviceId)): \(reason)")
            self.pairedDevices.removeValue(forKey: deviceId)
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func updateLastSeen(deviceId: String) {
        lock.withLock {
            guard var device = self.pairedDevices[deviceId] else { return }
            device.lastSeenDate = Date()
            self.pairedDevices[deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func updateSettings(deviceId: String, clipboard: Bool, notifications: Bool) {
        lock.withLock {
            guard var device = self.pairedDevices[deviceId] else { return }
            device.isClipboardSyncEnabled = clipboard
            device.isNotificationSyncEnabled = notifications
            self.pairedDevices[deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func setClipboardSyncEnabled(_ deviceId: String, isEnabled: Bool) {
        lock.withLock {
            guard var device = self.pairedDevices[deviceId] else { return }
            device.isClipboardSyncEnabled = isEnabled
            self.pairedDevices[deviceId] = device
            self.saveDevices()
        }
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
}
