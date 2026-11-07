//
//  NotificationGroupBuilder.swift
//  MacMate
//
//  Pure grouping, disambiguation, and filtering logic for notifications.
//

import Foundation

/// Represents a grouped collection of notifications from a single Android application.
public struct NotificationAppGroup: Identifiable, Equatable, Sendable {
    public let key: NotificationAppKey
    public var id: String { key.rawValue }
    public let displayName: String
    public let disambiguator: String?
    public let mode: NotificationMode
    public let items: [PhoneNotification]
    public let canConfigure: Bool
    public let canReset: Bool

    /// Backward-compatibility alias for canConfigure.
    public var isConfigurable: Bool { canConfigure }

    public var packageId: String? {
        key.isPackage ? key.identifier : nil
    }

    public init(
        key: NotificationAppKey,
        displayName: String,
        disambiguator: String? = nil,
        mode: NotificationMode,
        items: [PhoneNotification],
        canConfigure: Bool = true,
        canReset: Bool = false
    ) {
        self.key = key
        self.displayName = displayName
        self.disambiguator = disambiguator
        self.mode = mode
        self.items = items
        self.canConfigure = canConfigure
        self.canReset = canReset || mode != .normal
    }
}

/// Filter options for viewing notifications by their per-app mode.
public enum NotificationModeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case normal
    case silent
    case muted

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .normal: return "Normal"
        case .silent: return "Silent"
        case .muted: return "Muted"
        }
    }

    public var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .normal: return "bell"
        case .silent: return "bell.slash"
        case .muted: return "speaker.slash"
        }
    }
}

/// Pure builder for constructing, disambiguating, and filtering notification application groups.
public enum NotificationGroupBuilder {

    /// Checks if a key represents a legitimate, configurable application identity.
    /// Placeholder and malformed keys like `app:` or `app:notification` are unconfigurable.
    public static func isConfigurable(key: NotificationAppKey) -> Bool {
        if key.isPackage {
            return NativeNotificationFilter.isValidPackageName(key.identifier)
        }
        let id = key.identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.isEmpty || id == "notification" {
            return false
        }
        return true
    }

    /// Pure builder constructing deterministic application groups from notifications and customized entries.
    ///
    /// - Parameters:
    ///   - notifications: Active notifications on the device.
    ///   - customized: Snapshot of customized app entries from `NotificationModeStore`.
    /// - Returns: Deterministically ordered, disambiguated application groups.
    public static func build(
        notifications: [PhoneNotification],
        customized: [String: NotificationAppModeEntry]
    ) -> [NotificationAppGroup] {
        // 1. Group active notifications by NotificationAppKey
        var activeBuckets: [String: (key: NotificationAppKey, items: [PhoneNotification])] = [:]
        for item in notifications {
            let key = NotificationAppKey(notificationId: item.id, appName: item.appName)
            if activeBuckets[key.rawValue] == nil {
                activeBuckets[key.rawValue] = (key: key, items: [item])
            } else {
                activeBuckets[key.rawValue]?.items.append(item)
            }
        }

        // 2. Build initial groups for active notification buckets
        var rawGroups: [NotificationAppGroup] = []

        for (rawKey, bucket) in activeBuckets {
            let sortedItems = bucket.items.sorted { a, b in
                if a.date != b.date {
                    return a.date > b.date
                }
                return a.id < b.id
            }
            let newestName = sortedItems.first?.appName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedName: String
            if !newestName.isEmpty {
                resolvedName = newestName
            } else if let stored = customized[rawKey]?.displayName, !stored.isEmpty {
                resolvedName = stored
            } else {
                resolvedName = "Notification"
            }

            let mode = customized[rawKey]?.mode ?? .normal
            let configurable = isConfigurable(key: bucket.key)

            rawGroups.append(NotificationAppGroup(
                key: bucket.key,
                displayName: resolvedName,
                disambiguator: nil,
                mode: mode,
                items: sortedItems,
                canConfigure: configurable,
                canReset: mode != .normal
            ))
        }

        // 3. Add zero-notification customized apps
        for (rawKey, entry) in customized {
            guard activeBuckets[rawKey] == nil else { continue }
            guard entry.mode != .normal else { continue }

            let configurable = isConfigurable(key: entry.key)
            let resolvedName = entry.displayName.isEmpty ? entry.key.identifier : entry.displayName

            rawGroups.append(NotificationAppGroup(
                key: entry.key,
                displayName: resolvedName,
                disambiguator: nil,
                mode: entry.mode,
                items: [],
                canConfigure: configurable,
                canReset: true
            ))
        }

        // 4. Disambiguate duplicate display names
        var nameCounts: [String: Int] = [:]
        for group in rawGroups {
            let normalized = NotificationAppKey.normalizeAppName(group.displayName)
            nameCounts[normalized, default: 0] += 1
        }

        var disambiguatedGroups: [NotificationAppGroup] = []
        for group in rawGroups {
            let normalized = NotificationAppKey.normalizeAppName(group.displayName)
            let hasCollision = (nameCounts[normalized] ?? 0) > 1

            let disambiguator: String?
            if hasCollision {
                if group.key.isPackage {
                    disambiguator = group.key.identifier
                } else {
                    disambiguator = "No package ID"
                }
            } else {
                disambiguator = nil
            }

            disambiguatedGroups.append(NotificationAppGroup(
                key: group.key,
                displayName: group.displayName,
                disambiguator: disambiguator,
                mode: group.mode,
                items: group.items,
                canConfigure: group.canConfigure,
                canReset: group.canReset
            ))
        }

        // 5. Deterministic sort:
        //    - Active groups with items come first, sorted by newest item date descending.
        //    - Zero-item customized groups come after, sorted alphabetically by displayName.
        //    - Ties broken deterministically by key.rawValue.
        return disambiguatedGroups.sorted { a, b in
            let aHasItems = !a.items.isEmpty
            let bHasItems = !b.items.isEmpty

            if aHasItems && bHasItems {
                let aDate = a.items.first?.date ?? .distantPast
                let bDate = b.items.first?.date ?? .distantPast
                if aDate != bDate {
                    return aDate > bDate
                }
            } else if aHasItems != bHasItems {
                return aHasItems && !bHasItems
            } else {
                let nameCompare = a.displayName.localizedStandardCompare(b.displayName)
                if nameCompare != .orderedSame {
                    return nameCompare == .orderedAscending
                }
            }

            return a.key.rawValue < b.key.rawValue
        }
    }

    /// Filters groups according to the selected mode filter.
    public static func filter(
        _ groups: [NotificationAppGroup],
        by filter: NotificationModeFilter
    ) -> [NotificationAppGroup] {
        switch filter {
        case .all:
            return groups
        case .normal:
            return groups.filter { $0.mode == .normal && !$0.items.isEmpty }
        case .silent:
            return groups.filter { $0.mode == .silent }
        case .muted:
            return groups.filter { $0.mode == .muted }
        }
    }

    /// Returns all dismissable notifications from the provided application groups.
    /// Used by Clear All to ensure only notifications visible under the active filter
    /// are dismissed, while preserving device-side dismissal synchronization.
    public static func dismissableItems(in groups: [NotificationAppGroup]) -> [PhoneNotification] {
        groups.flatMap(\.items).filter(\.isDismissable)
    }
}

