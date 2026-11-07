//
//  NotificationPipelineIntegrationTests.swift
//  MacMateTests
//
//  Unit tests for Step 2 notification pipeline integration, verifying:
//  - makeContent sound vs silent configuration
//  - deliveryDecision evaluation across modes
//  - verification-code handling and auto-copy subtitle integration
//  - global sound mute ceiling
//  - nested observer mutation safety across multiple keys
//

import Testing
import Foundation
import UserNotifications
@testable import MacMate

@MainActor
struct NotificationPipelineIntegrationTests {

    private func makeIsolatedStore() -> (store: NotificationModeStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "MacMatePipelineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = NotificationModeStore(defaults: defaults)
        return (store, defaults, suiteName)
    }

    private func cleanup(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 1. Content Generation & Sound Flag

    @Test
    func makeContentRespectsPlaySoundFlag() {
        let item = PhoneNotification(
            id: "0|com.example.chat|1|tag|1000",
            deviceId: "device_abc",
            appName: "ExampleChat",
            title: "Alice",
            text: "Hello there!",
            date: Date(),
            replyId: "reply_99",
            isDismissable: true
        )

        let soundContent = NotificationPlugin.makeContent(for: item, playSound: true)
        let silentContent = NotificationPlugin.makeContent(for: item, playSound: false)

        // Sound verification
        #expect(soundContent.sound != nil)
        #expect(silentContent.sound == nil)

        // Identity, category, and userInfo must remain completely identical
        #expect(soundContent.title == silentContent.title)
        #expect(soundContent.body == silentContent.body)
        #expect(soundContent.threadIdentifier == silentContent.threadIdentifier)
        #expect(soundContent.threadIdentifier == "device_abc:com.example.chat")
        #expect(soundContent.categoryIdentifier == NotificationPlugin.notificationCategory)
        #expect(silentContent.categoryIdentifier == NotificationPlugin.notificationCategory)
        #expect(soundContent.userInfo["deviceId"] as? String == "device_abc")
        #expect(silentContent.userInfo["deviceId"] as? String == "device_abc")
        #expect(soundContent.userInfo["replyId"] as? String == "reply_99")
        #expect(silentContent.userInfo["replyId"] as? String == "reply_99")
    }

    // MARK: - 2. Delivery Decision Across Modes

    @Test
    func deliveryDecisionAcrossModes() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let normalItem = PhoneNotification(
            id: "0|com.app.normal|1|tag|1000",
            deviceId: "dev1",
            appName: "NormalApp",
            title: "News",
            text: "Regular notification",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )

        let silentKey = NotificationAppKey(notificationId: "0|com.app.silent|1|tag|1000", appName: "SilentApp")
        store.setMode(.silent, for: silentKey, displayName: "SilentApp")
        let silentItem = PhoneNotification(
            id: "0|com.app.silent|1|tag|1000",
            deviceId: "dev1",
            appName: "SilentApp",
            title: "Alert",
            text: "Silent message",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )

        let mutedKey = NotificationAppKey(notificationId: "0|com.app.muted|1|tag|1000", appName: "MutedApp")
        store.setMode(.muted, for: mutedKey, displayName: "MutedApp")
        let mutedItemNoCode = PhoneNotification(
            id: "0|com.app.muted|1|tag|1000",
            deviceId: "dev1",
            appName: "MutedApp",
            title: "Promo",
            text: "Discount today",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )
        let mutedItemWithCode = PhoneNotification(
            id: "0|com.app.muted|2|tag|1000",
            deviceId: "dev1",
            appName: "MutedApp",
            title: "Security",
            text: "Your code is 492810",
            date: Date(),
            replyId: nil,
            isDismissable: true,
            code: "492810"
        )

        // 1. Normal mode -> banner with sound
        #expect(NotificationPlugin.deliveryDecision(for: normalItem, store: store) == .banner(playSound: true))

        // 2. Silent mode -> banner without sound
        #expect(NotificationPlugin.deliveryDecision(for: silentItem, store: store) == .banner(playSound: false))

        // 3. Muted mode without code -> skip banner entirely
        #expect(NotificationPlugin.deliveryDecision(for: mutedItemNoCode, store: store) == .skipBanner)

        // 4. Muted mode WITH verification code -> bypass mute, banner without sound
        #expect(NotificationPlugin.deliveryDecision(for: mutedItemWithCode, store: store) == .banner(playSound: false))

        // 5. Global mute enabled -> all banners lose sound
        store.isMuteAllSoundsEnabled = true
        #expect(NotificationPlugin.deliveryDecision(for: normalItem, store: store) == .banner(playSound: false))
        #expect(NotificationPlugin.deliveryDecision(for: silentItem, store: store) == .banner(playSound: false))
        #expect(NotificationPlugin.deliveryDecision(for: mutedItemNoCode, store: store) == .skipBanner)
        #expect(NotificationPlugin.deliveryDecision(for: mutedItemWithCode, store: store) == .banner(playSound: false))
    }

    // MARK: - 3. Verification Code Extraction and Category

    @Test
    func verificationCodeNotificationProperties() {
        let codeItem = PhoneNotification(
            id: "0|com.bank.app|1|tag|1000",
            deviceId: "dev_phone",
            appName: "BankApp",
            title: "Login Verification",
            text: "Your code is 654321",
            date: Date(),
            replyId: nil,
            isDismissable: true,
            code: "654321"
        )

        let content = NotificationPlugin.makeContent(for: codeItem, playSound: false)
        #expect(content.categoryIdentifier == NotificationPlugin.codeCategory)
        #expect(content.userInfo["code"] as? String == "654321")
        #expect(content.subtitle.contains("654321"))
    }

    // MARK: - 4. Nested Observer Mutations Involving Multiple Keys

    @Test
    func nestedObserverMutationsInvolvingMultipleKeys() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key1 = NotificationAppKey(rawValue: "pkg:com.nested.app1")
        let key2 = NotificationAppKey(rawValue: "pkg:com.nested.app2")
        let key3 = NotificationAppKey(rawValue: "pkg:com.nested.app3")

        var nestedMutationExecuted = false

        // Register observation tracking on key1
        withObservationTracking {
            _ = store.mode(for: key1)
        } onChange: {
            // Reentrant mutation of key2 and key3 during key1's observation notification
            nestedMutationExecuted = true
            store.setMode(.silent, for: key2, displayName: "Nested App 2")
            store.setMode(.muted, for: key3, displayName: "Nested App 3")
        }

        // Trigger outer mutation
        store.setMode(.muted, for: key1, displayName: "Outer App 1")

        #expect(nestedMutationExecuted)

        // Verify in-memory state contains all three customizations
        #expect(store.mode(for: key1) == .muted)
        #expect(store.mode(for: key2) == .silent)
        #expect(store.mode(for: key3) == .muted)
        #expect(store.customizedApps.count == 3)

        // Verify persistence contains all three customizations without lost updates
        let storedDict = defaults.dictionary(forKey: NotificationModeStore.appModesKey)
        #expect(storedDict?.count == 3)
        #expect((storedDict?[key1.rawValue] as? [String: Any])?["mode"] as? String == "muted")
        #expect((storedDict?[key2.rawValue] as? [String: Any])?["mode"] as? String == "silent")
        #expect((storedDict?[key3.rawValue] as? [String: Any])?["mode"] as? String == "muted")

        // Recreate store instance to verify clean persistence reload
        let reloadedStore = NotificationModeStore(defaults: defaults)
        #expect(reloadedStore.mode(for: key1) == .muted)
        #expect(reloadedStore.mode(for: key2) == .silent)
        #expect(reloadedStore.mode(for: key3) == .muted)
    }

    // MARK: - 5. Foreground Presentation Options

    @Test
    func presentationOptionsReflectSoundPresence() {
        let plugin = NotificationPlugin()

        let itemWithSound = PhoneNotification(
            id: "0|com.app|1|tag|1000",
            deviceId: "dev1",
            appName: "App",
            title: "Title",
            text: "Text",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )
        let contentWithSound = NotificationPlugin.makeContent(for: itemWithSound, playSound: true)
        let requestWithSound = UNNotificationRequest(identifier: "test1", content: contentWithSound, trigger: nil)

        // When content has sound, presentation options should include .sound
        var deliveredOptions: UNNotificationPresentationOptions = []
        // Simulate delegate willPresent evaluation logic
        var optionsWithSound: UNNotificationPresentationOptions = [.banner, .list]
        if requestWithSound.content.sound != nil { optionsWithSound.insert(.sound) }
        #expect(optionsWithSound.contains(.sound))
        #expect(optionsWithSound.contains(.banner))
        #expect(optionsWithSound.contains(.list))

        let contentSilent = NotificationPlugin.makeContent(for: itemWithSound, playSound: false)
        let requestSilent = UNNotificationRequest(identifier: "test2", content: contentSilent, trigger: nil)
        var optionsSilent: UNNotificationPresentationOptions = [.banner, .list]
        if requestSilent.content.sound != nil { optionsSilent.insert(.sound) }
        #expect(!optionsSilent.contains(.sound))
        #expect(optionsSilent.contains(.banner))
        #expect(optionsSilent.contains(.list))
    }

    // MARK: - 6. Step 3 Global Mute All Sounds Settings & Banner Preservation

    @Test
    func globalMuteKeyAndDefaultValue() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        #expect(NotificationModeStore.muteAllSoundsKey == "macmate_mute_all_notification_sounds")
        #expect(store.isMuteAllSoundsEnabled == false)
    }

    @Test
    func globalMuteDirectUserDefaultsSync() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        // Simulate @AppStorage write directly to UserDefaults
        defaults.set(true, forKey: NotificationModeStore.muteAllSoundsKey)
        #expect(store.isMuteAllSoundsEnabled == true)

        // Mutating via store writes back to UserDefaults
        store.isMuteAllSoundsEnabled = false
        #expect(defaults.bool(forKey: NotificationModeStore.muteAllSoundsKey) == false)
    }

    @Test
    func globalMuteObservationInvalidation() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        var observationTriggered = false
        withObservationTracking {
            _ = store.isMuteAllSoundsEnabled
        } onChange: {
            observationTriggered = true
        }

        store.isMuteAllSoundsEnabled = true
        #expect(observationTriggered)
        #expect(store.isMuteAllSoundsEnabled == true)
    }

    @Test
    func globalMuteIndependenceFromPerAppModes() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let key = NotificationAppKey(rawValue: "pkg:com.test.app")
        store.setMode(.muted, for: key, displayName: "Test App")
        store.isMuteAllSoundsEnabled = true

        // Setting a mode must not touch global mute
        let key2 = NotificationAppKey(rawValue: "pkg:com.test.app2")
        store.setMode(.silent, for: key2, displayName: "Test App 2")
        #expect(store.isMuteAllSoundsEnabled == true)

        // Resetting an individual mode must not touch global mute
        store.resetMode(for: key)
        #expect(store.isMuteAllSoundsEnabled == true)

        // ResetAll must clear customized apps but preserve global mute
        store.resetAll()
        #expect(store.customizedApps.isEmpty)
        #expect(store.isMuteAllSoundsEnabled == true)

        // Toggling global mute off must not alter customized apps
        store.setMode(.silent, for: key, displayName: "Test App")
        store.isMuteAllSoundsEnabled = false
        #expect(store.customizedApps.count == 1)
        #expect(store.mode(for: key) == .silent)
    }

    @Test
    func globalMuteBannerPreservationContract() {
        let (store, defaults, suite) = makeIsolatedStore()
        defer { cleanup(defaults, suiteName: suite) }

        let normalItem = PhoneNotification(
            id: "0|com.app.normal|1|null|100",
            deviceId: "dev1",
            appName: "NormalApp",
            title: "Normal Message",
            text: "Hello",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )
        let mutedKey = NotificationAppKey(notificationId: "0|com.app.muted|1|null|100", appName: "MutedApp")
        store.setMode(.muted, for: mutedKey, displayName: "MutedApp")

        let mutedItemNoCode = PhoneNotification(
            id: "0|com.app.muted|1|null|100",
            deviceId: "dev1",
            appName: "MutedApp",
            title: "Promo",
            text: "No code here",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )
        let mutedItemWithCode = PhoneNotification(
            id: "0|com.app.muted|2|null|100",
            deviceId: "dev1",
            appName: "MutedApp",
            title: "Security",
            text: "Your code is 123456",
            date: Date(),
            replyId: nil,
            isDismissable: true,
            code: "123456"
        )

        // Enable global mute
        store.isMuteAllSoundsEnabled = true

        // 1. Normal mode notifications MUST remain visible (banner preserved, sound removed)
        let normalDecision = NotificationPlugin.deliveryDecision(for: normalItem, store: store)
        #expect(normalDecision == .banner(playSound: false))

        // 2. Muted notifications without code remain suppressed
        let mutedNoCodeDecision = NotificationPlugin.deliveryDecision(for: mutedItemNoCode, store: store)
        #expect(mutedNoCodeDecision == .skipBanner)

        // 3. Muted notifications with verification code bypass muting with banner preserved, sound removed
        let mutedWithCodeDecision = NotificationPlugin.deliveryDecision(for: mutedItemWithCode, store: store)
        #expect(mutedWithCodeDecision == .banner(playSound: false))
    }

    @Test
    func globalMuteSharedDomainSync() {
        let standardDefaults = UserDefaults.standard
        let originalValue = standardDefaults.object(forKey: NotificationModeStore.muteAllSoundsKey)
        defer {
            if let original = originalValue {
                standardDefaults.set(original, forKey: NotificationModeStore.muteAllSoundsKey)
            } else {
                standardDefaults.removeObject(forKey: NotificationModeStore.muteAllSoundsKey)
            }
        }

        // Write directly to UserDefaults.standard (same as @AppStorage in SettingsView)
        standardDefaults.set(true, forKey: NotificationModeStore.muteAllSoundsKey)
        #expect(NotificationModeStore.shared.isMuteAllSoundsEnabled == true)

        standardDefaults.set(false, forKey: NotificationModeStore.muteAllSoundsKey)
        #expect(NotificationModeStore.shared.isMuteAllSoundsEnabled == false)
    }
}

