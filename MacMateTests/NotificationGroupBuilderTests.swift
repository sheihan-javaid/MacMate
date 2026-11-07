//
//  NotificationGroupBuilderTests.swift
//  MacMateTests
//
//  Unit tests for NotificationGroupBuilder, NotificationAppGroup, and NotificationModeFilter.
//

import Testing
import Foundation
import AppKit
@testable import MacMate

@MainActor
struct NotificationGroupBuilderTests {

    private func makeIsolatedStore() -> (store: NotificationModeStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "MacMateGroupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = NotificationModeStore(defaults: defaults)
        return (store, defaults, suiteName)
    }

    private func cleanup(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 1. Package Identity and Key Derivation

    @Test
    func packageIdentityAndKeyDerivation() {
        let now = Date()
        let notif1 = PhoneNotification(
            id: "0|com.whatsapp|1|null|100",
            deviceId: "dev1",
            appName: "WhatsApp",
            title: "Alice",
            text: "Hello",
            date: now,
            replyId: nil,
            isDismissable: true
        )
        let notif2 = PhoneNotification(
            id: "0|com.whatsapp|2|null|100",
            deviceId: "dev1",
            appName: "WhatsApp",
            title: "Bob",
            text: "Hi",
            date: now.addingTimeInterval(-10),
            replyId: nil,
            isDismissable: true
        )
        let opaqueNotif = PhoneNotification(
            id: "opaque-999",
            deviceId: "dev1",
            appName: "Signal",
            title: "Charlie",
            text: "Hey",
            date: now.addingTimeInterval(-20),
            replyId: nil,
            isDismissable: true
        )

        let groups = NotificationGroupBuilder.build(
            notifications: [notif1, notif2, opaqueNotif],
            customized: [:]
        )

        #expect(groups.count == 2)

        let whatsappGroup = groups.first { $0.key.rawValue == "pkg:com.whatsapp" }
        #expect(whatsappGroup != nil)
        #expect(whatsappGroup?.displayName == "WhatsApp")
        #expect(whatsappGroup?.items.count == 2)
        #expect(whatsappGroup?.packageId == "com.whatsapp")
        #expect(whatsappGroup?.mode == .normal)
        #expect(whatsappGroup?.isConfigurable == true)

        let signalGroup = groups.first { $0.key.rawValue == "app:signal" }
        #expect(signalGroup != nil)
        #expect(signalGroup?.displayName == "Signal")
        #expect(signalGroup?.items.count == 1)
        #expect(signalGroup?.packageId == nil)
        #expect(signalGroup?.isConfigurable == true)
    }

    // MARK: - 2. Duplicate App Names Disambiguation

    @Test
    func duplicateAppNamesDisambiguatedByPackage() {
        let now = Date()
        let googleMessages = PhoneNotification(
            id: "0|com.google.android.apps.messaging|1|null|100",
            deviceId: "dev1",
            appName: "Messages",
            title: "Bank",
            text: "Your code is 123",
            date: now,
            replyId: nil,
            isDismissable: true
        )
        let samsungMessages = PhoneNotification(
            id: "0|com.samsung.android.messaging|2|null|100",
            deviceId: "dev1",
            appName: "Messages",
            title: "Mom",
            text: "Call me",
            date: now.addingTimeInterval(-30),
            replyId: nil,
            isDismissable: true
        )

        let groups = NotificationGroupBuilder.build(
            notifications: [googleMessages, samsungMessages],
            customized: [:]
        )

        #expect(groups.count == 2)
        let gGroup = groups.first { $0.key.rawValue == "pkg:com.google.android.apps.messaging" }
        let sGroup = groups.first { $0.key.rawValue == "pkg:com.samsung.android.messaging" }

        #expect(gGroup?.displayName == "Messages")
        #expect(sGroup?.displayName == "Messages")
        #expect(gGroup?.disambiguator == "com.google.android.apps.messaging")
        #expect(sGroup?.disambiguator == "com.samsung.android.messaging")
    }

    @Test
    func uniqueAppNamesHaveNoDisambiguator() {
        let notif1 = PhoneNotification(
            id: "0|com.slack|1|null|100",
            deviceId: "dev1",
            appName: "Slack",
            title: "Workspace",
            text: "Message",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )
        let notif2 = PhoneNotification(
            id: "0|com.telegram|1|null|100",
            deviceId: "dev1",
            appName: "Telegram",
            title: "Friend",
            text: "Message",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )

        let groups = NotificationGroupBuilder.build(
            notifications: [notif1, notif2],
            customized: [:]
        )

        #expect(groups.count == 2)
        #expect(groups[0].disambiguator == nil)
        #expect(groups[1].disambiguator == nil)
    }

    // MARK: - 3. Unicode Normalization (NFC / NFD)

    @Test
    func unicodeNormalizationNfcNfdGrouping() {
        let now = Date()
        let nfcNotif = PhoneNotification(
            id: "id_1",
            deviceId: "dev1",
            appName: "Caf\u{00E9}",
            title: "Order 1",
            text: "Ready",
            date: now,
            replyId: nil,
            isDismissable: true
        )
        let nfdNotif = PhoneNotification(
            id: "id_2",
            deviceId: "dev1",
            appName: "Cafe\u{0301}",
            title: "Order 2",
            text: "Picked up",
            date: now.addingTimeInterval(-10),
            replyId: nil,
            isDismissable: true
        )

        // Pass NFD notification first so the active bucket is seeded from the decomposed input
        let groups = NotificationGroupBuilder.build(
            notifications: [nfdNotif, nfcNotif],
            customized: [:]
        )

        // Must merge into a single group under "app:café"
        #expect(groups.count == 1)
        #expect(groups[0].key.rawValue == "app:caf\u{00E9}")
        #expect(groups[0].items.count == 2)

        // Strictly verify that the key.rawValue scalar composition is precomposed NFC (\u{00E9}),
        // and does NOT contain decomposed NFD combining acute accent (\u{0301}).
        let scalars = Array(groups[0].key.rawValue.unicodeScalars)
        #expect(scalars.contains(UnicodeScalar(0x00E9)!))
        #expect(!scalars.contains(UnicodeScalar(0x0301)!))

        // Direct assertion on NFD input normalized by NotificationAppKey
        let nfdDirectKey = NotificationAppKey(notificationId: "opaque", appName: "Cafe\u{0301}")
        let directScalars = Array(nfdDirectKey.rawValue.unicodeScalars)
        #expect(directScalars.contains(UnicodeScalar(0x00E9)!))
        #expect(!directScalars.contains(UnicodeScalar(0x0301)!))
    }

    @Test
    func deterministicItemSortingWithEqualTimestamps() {
        let now = Date()
        let notifC = PhoneNotification(id: "notif_c", deviceId: "d", appName: "App", title: "C", text: "", date: now, replyId: nil, isDismissable: true)
        let notifA = PhoneNotification(id: "notif_a", deviceId: "d", appName: "App", title: "A", text: "", date: now, replyId: nil, isDismissable: true)
        let notifB = PhoneNotification(id: "notif_b", deviceId: "d", appName: "App", title: "B", text: "", date: now, replyId: nil, isDismissable: true)

        let groups = NotificationGroupBuilder.build(notifications: [notifC, notifA, notifB], customized: [:])
        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.id) == ["notif_a", "notif_b", "notif_c"])
    }

    @Test
    func disambiguationForPackageVsFallbackIdentities() {
        let pkgNotif = PhoneNotification(
            id: "0|com.whatsapp|1|null|100",
            deviceId: "dev1",
            appName: "WhatsApp",
            title: "Msg 1",
            text: "Hello",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )
        let opaqueNotif = PhoneNotification(
            id: "opaque-1",
            deviceId: "dev1",
            appName: "WhatsApp",
            title: "Msg 2",
            text: "World",
            date: Date().addingTimeInterval(-10),
            replyId: nil,
            isDismissable: true
        )

        let groups = NotificationGroupBuilder.build(notifications: [pkgNotif, opaqueNotif], customized: [:])
        #expect(groups.count == 2)

        let pkgGroup = groups.first { $0.key.isPackage }
        let fallbackGroup = groups.first { !$0.key.isPackage }

        #expect(pkgGroup?.disambiguator == "com.whatsapp")
        #expect(fallbackGroup?.disambiguator == "No package ID")
        #expect(fallbackGroup?.disambiguator != fallbackGroup?.displayName)
    }

    @Test
    func existingCustomizedEntriesAlwaysOfferReset() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let placeholderKey = NotificationAppKey(rawValue: "app:notification")
        store.setMode(.muted, for: placeholderKey, displayName: "Notification")

        let groups = NotificationGroupBuilder.build(notifications: [], customized: store.customizedApps)
        #expect(groups.count == 1)
        #expect(groups[0].key == placeholderKey)
        #expect(groups[0].canConfigure == false)
        #expect(groups[0].canReset == true)

        // Resetting must succeed and clear the entry
        store.resetMode(for: placeholderKey)
        let groupsAfterReset = NotificationGroupBuilder.build(notifications: [], customized: store.customizedApps)
        #expect(groupsAfterReset.isEmpty)
    }

    @Test
    func dismissableItemsHelperWithActiveFilters() {
        let normalDismissable = PhoneNotification(id: "1", deviceId: "d", appName: "Normal", title: "", text: "", date: Date(), replyId: nil, isDismissable: true)
        let normalNonDismissable = PhoneNotification(id: "2", deviceId: "d", appName: "Normal", title: "", text: "", date: Date(), replyId: nil, isDismissable: false)
        let silentDismissable = PhoneNotification(id: "3", deviceId: "d", appName: "Silent", title: "", text: "", date: Date(), replyId: nil, isDismissable: true)
        let silentNonDismissable = PhoneNotification(id: "4", deviceId: "d", appName: "Silent", title: "", text: "", date: Date(), replyId: nil, isDismissable: false)

        let normalGroup = NotificationAppGroup(
            key: NotificationAppKey(rawValue: "pkg:com.normal"),
            displayName: "Normal",
            mode: .normal,
            items: [normalDismissable, normalNonDismissable]
        )
        let silentGroup = NotificationAppGroup(
            key: NotificationAppKey(rawValue: "pkg:com.silent"),
            displayName: "Silent",
            mode: .silent,
            items: [silentDismissable, silentNonDismissable]
        )

        let allGroups = [normalGroup, silentGroup]

        // Clear under .silent filter excludes hidden normal group and non-dismissable items
        let silentVisible = NotificationGroupBuilder.filter(allGroups, by: .silent)
        let silentDismissableOnly = NotificationGroupBuilder.dismissableItems(in: silentVisible)
        #expect(silentDismissableOnly.map(\.id) == ["3"])

        // Clear under .all filter includes dismissable items from all groups, excluding non-dismissable
        let allVisible = NotificationGroupBuilder.filter(allGroups, by: .all)
        let allDismissableOnly = NotificationGroupBuilder.dismissableItems(in: allVisible)
        #expect(allDismissableOnly.map(\.id) == ["1", "3"])
    }

    // MARK: - 4. Zero-Count Customized Apps

    @Test
    func zeroCountCustomizedAppsInclusionAndMerge() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let activeKey = NotificationAppKey(rawValue: "pkg:com.active.app")
        let mutedZeroCountKey = NotificationAppKey(rawValue: "pkg:com.muted.empty")
        let silentZeroCountKey = NotificationAppKey(rawValue: "pkg:com.silent.empty")

        store.setMode(.muted, for: activeKey, displayName: "Active App")
        store.setMode(.muted, for: mutedZeroCountKey, displayName: "Muted Empty App")
        store.setMode(.silent, for: silentZeroCountKey, displayName: "Silent Empty App")

        let activeNotif = PhoneNotification(
            id: "0|com.active.app|1|null|100",
            deviceId: "dev1",
            appName: "Active App (Updated)",
            title: "News",
            text: "Something happened",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )

        let groups = NotificationGroupBuilder.build(
            notifications: [activeNotif],
            customized: store.customizedApps
        )

        #expect(groups.count == 3)

        // 1. Active group merges with customized mode and uses live notification appName
        let activeGroup = groups.first { $0.key == activeKey }
        #expect(activeGroup != nil)
        #expect(activeGroup?.displayName == "Active App (Updated)")
        #expect(activeGroup?.mode == .muted)
        #expect(activeGroup?.items.count == 1)

        // 2. Zero-count groups use stored display name and have items == []
        let mutedGroup = groups.first { $0.key == mutedZeroCountKey }
        #expect(mutedGroup != nil)
        #expect(mutedGroup?.displayName == "Muted Empty App")
        #expect(mutedGroup?.mode == .muted)
        #expect(mutedGroup?.items.isEmpty == true)

        let silentGroup = groups.first { $0.key == silentZeroCountKey }
        #expect(silentGroup != nil)
        #expect(silentGroup?.displayName == "Silent Empty App")
        #expect(silentGroup?.mode == .silent)
        #expect(silentGroup?.items.isEmpty == true)
    }

    // MARK: - 5. Deterministic Sorting

    @Test
    func deterministicSortingOrder() {
        let now = Date()
        let olderDate = now.addingTimeInterval(-100)
        let newerDate = now.addingTimeInterval(-10)

        let olderItem = PhoneNotification(
            id: "0|com.app.older|1|null|100",
            deviceId: "dev1",
            appName: "Older App",
            title: "T1",
            text: "B1",
            date: olderDate,
            replyId: nil,
            isDismissable: true
        )
        let newerItem = PhoneNotification(
            id: "0|com.app.newer|1|null|100",
            deviceId: "dev1",
            appName: "Newer App",
            title: "T2",
            text: "B2",
            date: newerDate,
            replyId: nil,
            isDismissable: true
        )

        let customized: [String: NotificationAppModeEntry] = [
            "pkg:com.zero.zulu": NotificationAppModeEntry(
                key: NotificationAppKey(rawValue: "pkg:com.zero.zulu"),
                mode: .muted,
                displayName: "Zulu App"
            ),
            "pkg:com.zero.alpha": NotificationAppModeEntry(
                key: NotificationAppKey(rawValue: "pkg:com.zero.alpha"),
                mode: .silent,
                displayName: "Alpha App"
            )
        ]

        let groups = NotificationGroupBuilder.build(
            notifications: [olderItem, newerItem],
            customized: customized
        )

        #expect(groups.count == 4)
        // 1. Active groups come first, ordered newest date descending
        #expect(groups[0].displayName == "Newer App")
        #expect(groups[1].displayName == "Older App")

        // 2. Zero-count groups come after, ordered alphabetically by displayName
        #expect(groups[2].displayName == "Alpha App")
        #expect(groups[3].displayName == "Zulu App")
    }

    // MARK: - 6. Filter Logic Across All Modes

    @Test
    func filteringAcrossAllModes() {
        let normalGroup = NotificationAppGroup(
            key: NotificationAppKey(rawValue: "pkg:com.normal"),
            displayName: "Normal",
            mode: .normal,
            items: [PhoneNotification(id: "1", deviceId: "d", appName: "Normal", title: "", text: "", date: Date(), replyId: nil, isDismissable: true)]
        )
        let silentGroup = NotificationAppGroup(
            key: NotificationAppKey(rawValue: "pkg:com.silent"),
            displayName: "Silent",
            mode: .silent,
            items: [PhoneNotification(id: "2", deviceId: "d", appName: "Silent", title: "", text: "", date: Date(), replyId: nil, isDismissable: true)]
        )
        let mutedActiveGroup = NotificationAppGroup(
            key: NotificationAppKey(rawValue: "pkg:com.muted.active"),
            displayName: "Muted Active",
            mode: .muted,
            items: [PhoneNotification(id: "3", deviceId: "d", appName: "Muted Active", title: "", text: "", date: Date(), replyId: nil, isDismissable: true)]
        )
        let mutedZeroCountGroup = NotificationAppGroup(
            key: NotificationAppKey(rawValue: "pkg:com.muted.empty"),
            displayName: "Muted Empty",
            mode: .muted,
            items: []
        )

        let allGroups = [normalGroup, silentGroup, mutedActiveGroup, mutedZeroCountGroup]

        // 1. .all includes all groups
        let allFiltered = NotificationGroupBuilder.filter(allGroups, by: .all)
        #expect(allFiltered.count == 4)

        // 2. .normal includes only active normal groups
        let normalFiltered = NotificationGroupBuilder.filter(allGroups, by: .normal)
        #expect(normalFiltered.count == 1)
        #expect(normalFiltered[0].displayName == "Normal")

        // 3. .silent includes silent groups
        let silentFiltered = NotificationGroupBuilder.filter(allGroups, by: .silent)
        #expect(silentFiltered.count == 1)
        #expect(silentFiltered[0].displayName == "Silent")

        // 4. .muted includes both active and zero-count muted groups
        let mutedFiltered = NotificationGroupBuilder.filter(allGroups, by: .muted)
        #expect(mutedFiltered.count == 2)
        #expect(mutedFiltered.contains { $0.displayName == "Muted Active" })
        #expect(mutedFiltered.contains { $0.displayName == "Muted Empty" })
    }

    // MARK: - 7. Placeholder Immunity

    @Test
    func placeholderIdentitiesUnconfigurable() {
        let emptyAppKey = NotificationAppKey(rawValue: "app:")
        let genericNotifKey = NotificationAppKey(rawValue: "app:notification")
        let legitimateAppKey = NotificationAppKey(rawValue: "app:slack")
        let legitimatePkgKey = NotificationAppKey(rawValue: "pkg:com.whatsapp")

        #expect(!NotificationGroupBuilder.isConfigurable(key: emptyAppKey))
        #expect(!NotificationGroupBuilder.isConfigurable(key: genericNotifKey))
        #expect(NotificationGroupBuilder.isConfigurable(key: legitimateAppKey))
        #expect(NotificationGroupBuilder.isConfigurable(key: legitimatePkgKey))
    }

    // MARK: - 8. AppIconResolver Cache & Distinct Keys

    @Test
    func appIconResolverDistinctCacheKeysAndImageCache() {
        let resolver = AppIconResolver.shared
        resolver.removeAll()

        let pkgKey = AppIconResolver.cacheKey(forPackage: "com.slack", appName: "Slack")
        let appKey = AppIconResolver.cacheKey(forPackage: nil, appName: "Slack")

        #expect(pkgKey as String == "pkg:com.slack")
        #expect(appKey as String == "app:slack")
        #expect(pkgKey != appKey)

        // Test cached image returns identical instance
        let image1 = resolver.tileImage(forPackage: "com.slack", appName: "Slack")
        let image2 = resolver.tileImage(forPackage: "com.slack", appName: "Slack")
        #expect(image1 != nil)
        #expect(image1 === image2)
    }

    // MARK: - 9. Individual and Global Resets Interaction with Builder

    @Test
    func individualAndGlobalResetsReflectedInBuilder() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key1 = NotificationAppKey(rawValue: "pkg:com.app1")
        let key2 = NotificationAppKey(rawValue: "pkg:com.app2")

        store.setMode(.silent, for: key1, displayName: "App 1")
        store.setMode(.muted, for: key2, displayName: "App 2")

        var groups = NotificationGroupBuilder.build(notifications: [], customized: store.customizedApps)
        #expect(groups.count == 2)

        // Reset individual mode
        store.resetMode(for: key1)
        groups = NotificationGroupBuilder.build(notifications: [], customized: store.customizedApps)
        #expect(groups.count == 1)
        #expect(groups[0].key == key2)

        // Reset all
        store.resetAll()
        groups = NotificationGroupBuilder.build(notifications: [], customized: store.customizedApps)
        #expect(groups.isEmpty)
    }
}

