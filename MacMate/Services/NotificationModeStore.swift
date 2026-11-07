//
//  NotificationModeStore.swift
//  MacMate
//
//  Manages per-app notification modes (normal, silent, muted) and global
//  sound preferences, backed by UserDefaults.
//

import Foundation
import Observation

/// The notification delivery mode for an app across all paired devices.
public enum NotificationMode: String, Codable, CaseIterable, Sendable {
    /// Native banner and notification sound.
    case normal
    /// Native banner without sound.
    case silent
    /// No native banner; notification remains visible in the in-app list only.
    case muted
}

/// Identifies an app across devices, keyed primarily by Android package name
/// and falling back to a normalized app name when no valid package name is present.
public struct NotificationAppKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(packageName: String?, fallbackAppName: String) {
        if let packageName = packageName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !packageName.isEmpty,
           NativeNotificationFilter.isValidPackageName(packageName) {
            self.rawValue = "pkg:\(packageName)"
        } else {
            self.rawValue = "app:\(Self.normalizeAppName(fallbackAppName))"
        }
    }

    public init(notificationId: String, appName: String) {
        let package = NativeNotificationFilter.extractPackageName(from: notificationId)
        self.init(packageName: package, fallbackAppName: appName)
    }

    public var isPackage: Bool { rawValue.hasPrefix("pkg:") }

    public var identifier: String {
        if rawValue.hasPrefix("pkg:") {
            return String(rawValue.dropFirst(4))
        } else if rawValue.hasPrefix("app:") {
            return String(rawValue.dropFirst(4))
        }
        return rawValue
    }

    /// Canonical Unicode precomposed, trimmed, and lowercased app name normalizer.
    public static func normalizeAppName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// A stored customization entry containing the mode and the display name.
public struct NotificationAppModeEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { key.rawValue }
    public let key: NotificationAppKey
    public var mode: NotificationMode
    public var displayName: String

    public init(key: NotificationAppKey, mode: NotificationMode, displayName: String) {
        self.key = key
        self.mode = mode
        self.displayName = displayName
    }
}

/// Pure delivery decision indicating whether to display a native banner and whether to play sound.
public enum NotificationDelivery: Equatable, Sendable {
    case skipBanner
    case banner(playSound: Bool)

    /// Computes the notification delivery behavior.
    ///
    /// - Parameters:
    ///   - mode: The per-app notification mode.
    ///   - hasCode: Whether the notification contains a one-time verification code.
    ///   - muteAllSounds: Whether the global "mute all notification sounds" toggle is enabled.
    /// - Returns: The delivery decision (`skipBanner` or `banner(playSound:)`).
    public static func decide(
        mode: NotificationMode,
        hasCode: Bool,
        muteAllSounds: Bool
    ) -> NotificationDelivery {
        switch mode {
        case .normal:
            return .banner(playSound: !muteAllSounds)
        case .silent:
            return .banner(playSound: false)
        case .muted:
            // Verification-code notifications must still be delivered and copied
            // even for muted apps. They are delivered with a banner, but without sound.
            if hasCode {
                return .banner(playSound: false)
            } else {
                return .skipBanner
            }
        }
    }
}

/// Thread-safe settings store backed by UserDefaults for per-app notification modes
/// and global notification sound preferences.
@Observable
public final class NotificationModeStore: @unchecked Sendable {
    public static let shared = NotificationModeStore()

    public static let appModesKey = "macmate_notification_app_modes_v1"
    public static let legacyAppModesKey = "macmate_notification_app_modes.v1"
    public static let muteAllSoundsKey = "macmate_mute_all_notification_sounds"

    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()

    /// Tracked revision counter that invalidates observing SwiftUI views when settings change.
    public private(set) var revision: Int = 0

    @ObservationIgnored
    private var isBumpingRevision = false
    @ObservationIgnored
    private var needsAnotherBump = false

    @ObservationIgnored
    private var _customizedApps: [String: NotificationAppModeEntry] = [:]

    /// All customized apps with non-default modes (excludes .normal entries).
    /// Thread-safe and observable.
    public var customizedApps: [String: NotificationAppModeEntry] {
        _ = revision
        lock.lock()
        defer { lock.unlock() }
        return _customizedApps
    }

    /// Live global switch to mute all notification alert sounds.
    /// Directly backed by UserDefaults to remain synchronized with @AppStorage.
    public var isMuteAllSoundsEnabled: Bool {
        get {
            _ = revision
            return defaults.bool(forKey: Self.muteAllSoundsKey)
        }
        set {
            defaults.set(newValue, forKey: Self.muteAllSoundsKey)
            bumpRevision()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadCustomizedApps()
    }

    private func bumpRevision() {
        lock.lock()
        if isBumpingRevision {
            needsAnotherBump = true
            lock.unlock()
            return
        }
        isBumpingRevision = true
        lock.unlock()

        while true {
            revision &+= 1

            lock.lock()
            if needsAnotherBump {
                needsAnotherBump = false
                lock.unlock()
                continue
            }
            isBumpingRevision = false
            lock.unlock()
            break
        }
    }

    private func loadCustomizedApps() {
        lock.lock()
        defer { lock.unlock() }

        let rawDict = defaults.dictionary(forKey: Self.appModesKey)
            ?? defaults.dictionary(forKey: Self.legacyAppModesKey)

        guard let rawDict else {
            self._customizedApps = [:]
            return
        }

        var result: [String: NotificationAppModeEntry] = [:]
        for (rawKey, val) in rawDict {
            guard let dict = val as? [String: Any],
                  let modeStr = dict["mode"] as? String,
                  let mode = NotificationMode(rawValue: modeStr),
                  mode != .normal else {
                continue
            }
            let key = NotificationAppKey(rawValue: rawKey)
            let trimmedName = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = trimmedName.isEmpty ? key.identifier : String(trimmedName.prefix(100))
            result[rawKey] = NotificationAppModeEntry(key: key, mode: mode, displayName: displayName)
        }
        self._customizedApps = result

        // Migrate legacy key if present and primary key is missing
        if defaults.dictionary(forKey: Self.appModesKey) == nil,
           defaults.dictionary(forKey: Self.legacyAppModesKey) != nil {
            defaults.set(rawDict, forKey: Self.appModesKey)
        }
    }

    /// Returns the effective notification mode for the given app key (defaults to `.normal`).
    /// Reads from the observable `revision` state, ensuring SwiftUI views establish
    /// an observation dependency and re-render when modes change.
    public func mode(for key: NotificationAppKey) -> NotificationMode {
        _ = revision
        lock.lock()
        defer { lock.unlock() }
        return _customizedApps[key.rawValue]?.mode ?? .normal
    }

    /// Sets the notification mode for an app. Setting `.normal` removes the stored customization.
    public func setMode(_ mode: NotificationMode, for key: NotificationAppKey, displayName: String) {
        lock.lock()

        var rawDict = defaults.dictionary(forKey: Self.appModesKey)
            ?? defaults.dictionary(forKey: Self.legacyAppModesKey)
            ?? [:]

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? key.identifier : String(trimmedName.prefix(100))

        if mode == .normal {
            // If already uncustomized, exit early without unnecessary UserDefaults write or revision bump
            guard _customizedApps[key.rawValue] != nil || rawDict[key.rawValue] != nil else {
                lock.unlock()
                return
            }
            rawDict.removeValue(forKey: key.rawValue)
            _customizedApps.removeValue(forKey: key.rawValue)
        } else {
            rawDict[key.rawValue] = [
                "mode": mode.rawValue,
                "name": resolvedName
            ]
            _customizedApps[key.rawValue] = NotificationAppModeEntry(key: key, mode: mode, displayName: resolvedName)
        }

        // Commit to persistence before releasing lock and notifying observers
        defaults.set(rawDict, forKey: Self.appModesKey)
        lock.unlock()

        // Bump revision safely without reentrant observation deadlock or trap
        bumpRevision()
    }

    /// Resets the mode for the specified app back to `.normal`.
    public func resetMode(for key: NotificationAppKey) {
        setMode(.normal, for: key, displayName: "")
    }

    /// Resets all customized apps back to `.normal`, while preserving unknown future entries in storage.
    public func resetAll() {
        lock.lock()

        var rawDict = defaults.dictionary(forKey: Self.appModesKey)
            ?? defaults.dictionary(forKey: Self.legacyAppModesKey)
            ?? [:]

        for key in _customizedApps.keys {
            rawDict.removeValue(forKey: key)
        }

        if rawDict.isEmpty {
            defaults.removeObject(forKey: Self.appModesKey)
            defaults.removeObject(forKey: Self.legacyAppModesKey)
        } else {
            defaults.set(rawDict, forKey: Self.appModesKey)
        }

        _customizedApps.removeAll()
        lock.unlock()

        bumpRevision()
    }

    /// Returns all customized app entries sorted alphabetically by display name.
    public func allCustomizedApps() -> [NotificationAppModeEntry] {
        _ = revision
        lock.lock()
        defer { lock.unlock() }

        return Array(_customizedApps.values)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
