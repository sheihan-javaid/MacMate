//
//  NotificationModeStoreTests.swift
//  MacMateTests
//
//  Unit tests for NotificationMode, NotificationAppKey, NotificationDelivery,
//  and NotificationModeStore.
//

import Testing
import Foundation
@testable import MacMate

@MainActor
struct NotificationModeStoreTests {

    private func makeIsolatedStore() -> (store: NotificationModeStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "MacMateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = NotificationModeStore(defaults: defaults)
        return (store, defaults, suiteName)
    }

    private func cleanup(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 1. Golden Raw Values

    @Test
    func goldenRawValues() {
        #expect(NotificationMode.normal.rawValue == "normal")
        #expect(NotificationMode.silent.rawValue == "silent")
        #expect(NotificationMode.muted.rawValue == "muted")
        #expect(NotificationMode.allCases == [.normal, .silent, .muted])
    }

    // MARK: - 2. Key Derivation & Consistency

    @Test
    func keyDerivationValidPackage() {
        let key = NotificationAppKey(notificationId: "0|com.example.app|1|tag|1000", appName: "Example")
        #expect(key.rawValue == "pkg:com.example.app")
        #expect(key.identifier == "com.example.app")
        #expect(key.isPackage)
        #expect(key.description == "pkg:com.example.app")
    }

    @Test
    func keyDerivationCaseSensitivePackage() {
        let key = NotificationAppKey(notificationId: "0|com.Slack|42|tag|1000", appName: "Slack")
        #expect(key.rawValue == "pkg:com.Slack")
        #expect(key.identifier == "com.Slack")
        #expect(key.isPackage)
    }

    @Test
    func keyDerivationOpaqueIdFallback() {
        let key = NotificationAppKey(notificationId: "opaque-987", appName: "WhatsApp")
        #expect(key.rawValue == "app:whatsapp")
        #expect(key.identifier == "whatsapp")
        #expect(!key.isPackage)
    }

    @Test
    func keyDerivationWhitespaceAndNonAsciiFallback() {
        let trimmedKey = NotificationAppKey(notificationId: "12345", appName: "  Telegram  ")
        #expect(trimmedKey.rawValue == "app:telegram")

        // Non-ASCII candidate should be rejected as an Android package name and fall back to app name
        let nonAsciiKey = NotificationAppKey(notificationId: "0|com.экзампл.app|1|tag|1000", appName: "CustomApp")
        #expect(nonAsciiKey.rawValue == "app:customapp")
    }

    @Test
    func nfcNfdUnicodeNormalization() {
        // "Café": NFC (composite \u{00E9}) vs NFD (decomposed e + \u{0301})
        let nfcApp = "Caf\u{00E9}"
        let nfdApp = "Cafe\u{0301}"
        let keyNFC = NotificationAppKey(notificationId: "123", appName: nfcApp)
        let keyNFD = NotificationAppKey(notificationId: "123", appName: nfdApp)
        #expect(keyNFC.rawValue == keyNFD.rawValue)
        #expect(keyNFC.rawValue == "app:caf\u{00E9}")

        // "Ångström": NFC vs NFD
        let angstromNFC = "\u{00C5}ngstr\u{00F6}m"
        let angstromNFD = "A\u{030A}ngstro\u{0308}m"
        let keyAngstromNFC = NotificationAppKey(notificationId: "999", appName: angstromNFC)
        let keyAngstromNFD = NotificationAppKey(notificationId: "999", appName: angstromNFD)
        #expect(keyAngstromNFC.rawValue == keyAngstromNFD.rawValue)
    }

    @Test
    func packageValidationConsistencyAcrossModules() {
        let validPkg = "com.Slack"
        #expect(NativeNotificationFilter.isValidPackageName(validPkg))
        #expect(NativeNotificationFilter.extractPackageName(from: "0|\(validPkg)|1|null|100") == validPkg)
        #expect(NotificationAppKey(notificationId: "0|\(validPkg)|1|null|100", appName: "Slack").rawValue == "pkg:\(validPkg)")

        let nonAsciiPkg = "com.экзампл.app"
        #expect(!NativeNotificationFilter.isValidPackageName(nonAsciiPkg))
        #expect(NativeNotificationFilter.extractPackageName(from: "0|\(nonAsciiPkg)|1|null|100") == nil)
        #expect(NotificationAppKey(notificationId: "0|\(nonAsciiPkg)|1|null|100", appName: "Fallback").rawValue == "app:fallback")
    }

    // MARK: - 3. Delivery Decision (All 12 Combinations)

    @Test(arguments: [
        // Mode: Normal
        (NotificationMode.normal, false, false, NotificationDelivery.banner(playSound: true)),
        (NotificationMode.normal, false, true, NotificationDelivery.banner(playSound: false)),
        (NotificationMode.normal, true, false, NotificationDelivery.banner(playSound: true)),
        (NotificationMode.normal, true, true, NotificationDelivery.banner(playSound: false)),

        // Mode: Silent
        (NotificationMode.silent, false, false, NotificationDelivery.banner(playSound: false)),
        (NotificationMode.silent, false, true, NotificationDelivery.banner(playSound: false)),
        (NotificationMode.silent, true, false, NotificationDelivery.banner(playSound: false)),
        (NotificationMode.silent, true, true, NotificationDelivery.banner(playSound: false)),

        // Mode: Muted without code
        (NotificationMode.muted, false, false, NotificationDelivery.skipBanner),
        (NotificationMode.muted, false, true, NotificationDelivery.skipBanner),

        // Mode: Muted with verification code (bypasses banner mute, sound silenced)
        (NotificationMode.muted, true, false, NotificationDelivery.banner(playSound: false)),
        (NotificationMode.muted, true, true, NotificationDelivery.banner(playSound: false)),
    ])
    func deliveryDecideAllCombinations(
        mode: NotificationMode,
        hasCode: Bool,
        muteAll: Bool,
        expected: NotificationDelivery
    ) {
        let decision = NotificationDelivery.decide(mode: mode, hasCode: hasCode, muteAllSounds: muteAll)
        #expect(decision == expected)
    }

    // MARK: - 4. Observation & Reentrancy

    @Test
    func observationInvalidationOnModeChange() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key = NotificationAppKey(rawValue: "pkg:com.observable.test")
        var observationFired = false

        // Register observation tracking on mode(for:)
        withObservationTracking {
            _ = store.mode(for: key)
        } onChange: {
            observationFired = true
        }

        #expect(!observationFired)
        store.setMode(.muted, for: key, displayName: "Observable App")
        #expect(observationFired)
    }

    @Test
    func observationInvalidationOnAllCustomizedApps() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key = NotificationAppKey(rawValue: "pkg:com.list.test")
        var observationFired = false

        withObservationTracking {
            _ = store.allCustomizedApps()
        } onChange: {
            observationFired = true
        }

        #expect(!observationFired)
        store.setMode(.silent, for: key, displayName: "List App")
        #expect(observationFired)
    }

    @Test
    func synchronousObserverReentrancyWithoutDeadlock() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key = NotificationAppKey(rawValue: "pkg:com.reentrant.test")
        var reentrantReadMode: NotificationMode?

        withObservationTracking {
            _ = store.mode(for: key)
        } onChange: {
            // Reentrant synchronous read of store inside observer callback.
            // With revision bumped after releasing lock, observers safely see the committed state.
            reentrantReadMode = store.mode(for: key)
        }

        store.setMode(.silent, for: key, displayName: "Reentrant App")
        #expect(reentrantReadMode == .silent)
        #expect(store.mode(for: key) == .silent)
    }

    // MARK: - 5. Store: Default and Round-Trip

    @Test
    func defaultModeIsNormal() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key = NotificationAppKey(rawValue: "pkg:com.test.unknown")
        #expect(store.mode(for: key) == .normal)
        #expect(store.customizedApps.isEmpty)
        #expect(store.allCustomizedApps().isEmpty)
    }

    @Test
    func setAndRetrieveModes() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key1 = NotificationAppKey(rawValue: "pkg:com.test.silent")
        let key2 = NotificationAppKey(rawValue: "pkg:com.test.muted")

        store.setMode(.silent, for: key1, displayName: "Test Silent")
        store.setMode(.muted, for: key2, displayName: "Test Muted")

        #expect(store.mode(for: key1) == .silent)
        #expect(store.mode(for: key2) == .muted)
        #expect(store.customizedApps.count == 2)
    }

    // MARK: - 6. Setting .normal Removes the Key

    @Test
    func settingNormalRemovesKey() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key = NotificationAppKey(rawValue: "pkg:com.test.app")
        store.setMode(.silent, for: key, displayName: "Test App")
        #expect(store.mode(for: key) == .silent)

        // Raw dictionary in UserDefaults contains the entry
        let dictBefore = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(dictBefore?[key.rawValue] != nil)

        // Setting to .normal must remove it
        store.setMode(.normal, for: key, displayName: "Test App")
        #expect(store.mode(for: key) == .normal)
        #expect(store.customizedApps[key.rawValue] == nil)

        let dictAfter = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(dictAfter?[key.rawValue] == nil)
    }

    // MARK: - 7. Recovery, Name Sanitization & Single Source of Truth

    @Test
    func missingOrMalformedDisplayNameRecoveryAndReset() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let missingNameKey = "pkg:com.noname.app"
        let whitespaceNameKey = "app:whitespacename"
        let wrongTypeNameKey = "pkg:com.wrongtype.app"

        let initialDict: [String: [String: Any]] = [
            missingNameKey: ["mode": "muted"],
            whitespaceNameKey: ["mode": "silent", "name": "   \n  "],
            wrongTypeNameKey: ["mode": "muted", "name": 12345]
        ]
        defaults.set(initialDict, forKey: NotificationModeStore.appModesKey)

        // Recreate store to trigger loadCustomizedApps
        let loadedStore = NotificationModeStore(defaults: defaults)

        let key1 = NotificationAppKey(rawValue: missingNameKey)
        let key2 = NotificationAppKey(rawValue: whitespaceNameKey)
        let key3 = NotificationAppKey(rawValue: wrongTypeNameKey)

        // Modes must be active
        #expect(loadedStore.mode(for: key1) == .muted)
        #expect(loadedStore.mode(for: key2) == .silent)
        #expect(loadedStore.mode(for: key3) == .muted)

        // Entries must appear in customizedApps with fallback display names (not dropped)
        #expect(loadedStore.customizedApps[missingNameKey]?.displayName == "com.noname.app")
        #expect(loadedStore.customizedApps[whitespaceNameKey]?.displayName == "whitespacename")
        #expect(loadedStore.customizedApps[wrongTypeNameKey]?.displayName == "com.wrongtype.app")

        // Entries must be resettable
        loadedStore.resetMode(for: key1)
        #expect(loadedStore.mode(for: key1) == .normal)
        #expect(loadedStore.customizedApps[missingNameKey] == nil)
        let dictAfter = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(dictAfter?[missingNameKey] == nil)
    }

    @Test
    func displayNameTrimmingAndCapping() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key = NotificationAppKey(rawValue: "pkg:com.longname.app")
        let excessiveName = "   " + String(repeating: "Z", count: 150) + "   "
        store.setMode(.silent, for: key, displayName: excessiveName)

        let entry = store.customizedApps[key.rawValue]
        #expect(entry?.displayName.count == 100)
        #expect(entry?.displayName == String(repeating: "Z", count: 100))
    }

    // MARK: - 8. Unknown and Invalid Entries Preserved Without Crashing

    @Test
    func unknownStoredModeTreatedAsNormalAndPreservedAcrossWritesAndResetAll() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        // Manually write an unknown mode to UserDefaults
        let unknownKey = "pkg:com.future.app"
        let initialDict: [String: [String: Any]] = [
            unknownKey: [
                "mode": "ultra_quiet",
                "name": "Future App"
            ]
        ]
        defaults.set(initialDict, forKey: NotificationModeStore.appModesKey)

        // Reading should not crash and return .normal
        let appKey = NotificationAppKey(rawValue: unknownKey)
        #expect(store.mode(for: appKey) == .normal)

        // Storing a new customized app must preserve the unknown entry in defaults
        let newKey = NotificationAppKey(rawValue: "pkg:com.known.app")
        store.setMode(.muted, for: newKey, displayName: "Known App")

        var storedDict = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(storedDict?[newKey.rawValue] != nil)
        #expect((storedDict?[unknownKey] as? [String: Any])?["mode"] as? String == "ultra_quiet")

        // ResetAll should clear known apps but preserve unknown future entries
        store.resetAll()
        #expect(store.mode(for: newKey) == .normal)
        #expect(store.customizedApps.isEmpty)

        storedDict = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(storedDict?[newKey.rawValue] == nil)
        #expect((storedDict?[unknownKey] as? [String: Any])?["mode"] as? String == "ultra_quiet")
    }

    @Test
    func corruptedStorageHandledGracefully() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        // Store invalid type under the key
        defaults.set("not a dictionary", forKey: NotificationModeStore.appModesKey)

        let key = NotificationAppKey(rawValue: "pkg:com.test")
        #expect(store.mode(for: key) == .normal)

        // Writing should recover and overwrite with a valid dictionary
        store.setMode(.silent, for: key, displayName: "Test")
        #expect(store.mode(for: key) == .silent)

        let dict = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(dict?[key.rawValue] != nil)
    }

    // MARK: - 9. Reset and Reset All

    @Test
    func resetAndResetAll() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key1 = NotificationAppKey(rawValue: "pkg:com.app1")
        let key2 = NotificationAppKey(rawValue: "pkg:com.app2")

        store.setMode(.silent, for: key1, displayName: "App 1")
        store.setMode(.muted, for: key2, displayName: "App 2")
        #expect(store.customizedApps.count == 2)

        // Reset individual mode
        store.resetMode(for: key1)
        #expect(store.mode(for: key1) == .normal)
        #expect(store.mode(for: key2) == .muted)
        #expect(store.customizedApps.count == 1)

        // Reset all
        store.resetAll()
        #expect(store.mode(for: key2) == .normal)
        #expect(store.customizedApps.isEmpty)
        #expect(defaults.dictionary(forKey: NotificationModeStore.appModesKey) == nil)
    }

    // MARK: - 10. Live Global Mute Direct UserDefaults Writes

    @Test
    func liveGlobalMuteReflectsDirectUserDefaultsWrites() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        #expect(store.isMuteAllSoundsEnabled == false)

        // Simulate @AppStorage write directly to UserDefaults
        defaults.set(true, forKey: NotificationModeStore.muteAllSoundsKey)
        #expect(store.isMuteAllSoundsEnabled == true)

        // Update via store property writes back to UserDefaults
        store.isMuteAllSoundsEnabled = false
        #expect(defaults.bool(forKey: NotificationModeStore.muteAllSoundsKey) == false)
    }

    // MARK: - 11. Legacy Storage Key Migration

    @Test
    func legacyStorageKeyMigration() {
        let suiteName = "MacMateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Populate under legacy key format with dot
        let legacyDict: [String: [String: Any]] = [
            "pkg:com.legacy.app": [
                "mode": "muted",
                "name": "Legacy App"
            ]
        ]
        defaults.set(legacyDict, forKey: NotificationModeStore.legacyAppModesKey)

        let store = NotificationModeStore(defaults: defaults)
        let key = NotificationAppKey(rawValue: "pkg:com.legacy.app")
        #expect(store.mode(for: key) == .muted)
        #expect(store.customizedApps[key.rawValue]?.displayName == "Legacy App")

        // Should be migrated to new key format
        let migratedDict = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(migratedDict?[key.rawValue] != nil)
    }

    // MARK: - 12. Persistence Across Store Instances

    @Test
    func persistenceAcrossInstances() {
        let suiteName = "MacMateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = NotificationModeStore(defaults: defaults)
        let key = NotificationAppKey(rawValue: "pkg:com.persisted.app")
        store1.setMode(.muted, for: key, displayName: "Persisted App")
        store1.isMuteAllSoundsEnabled = true

        // Recreate store with same defaults
        let store2 = NotificationModeStore(defaults: defaults)
        #expect(store2.mode(for: key) == .muted)
        #expect(store2.isMuteAllSoundsEnabled == true)
        #expect(store2.customizedApps[key.rawValue]?.displayName == "Persisted App")
    }

    // MARK: - 13. Concurrent Mutations Without Persistence/State Divergence

    @Test
    func concurrentMutationsWithoutStateDivergence() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let iterations = 100
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let key = NotificationAppKey(rawValue: "pkg:com.concurrent.app.\(i)")
            store.setMode(.silent, for: key, displayName: "Concurrent App \(i)")
        }

        // All distinct keys must be present without data loss or race corruption
        let allApps = store.allCustomizedApps()
        #expect(allApps.count == iterations)
        #expect(store.customizedApps.count == iterations)

        let storedDict = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(storedDict?.count == iterations)

        for i in 0..<iterations {
            let key = NotificationAppKey(rawValue: "pkg:com.concurrent.app.\(i)")
            #expect(store.mode(for: key) == .silent)
            #expect(store.customizedApps[key.rawValue]?.mode == .silent)
        }
    }
}
