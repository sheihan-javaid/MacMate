//
//  FreshInstallTests.swift
//  MacMateTests
//
//  MacMate is an independent app: a first launch starts from its own defaults
//  and its own folders, and never reads, imports, changes or deletes data that
//  belongs to Tether, KDE Connect or any other application.
//
//  Every test works in a temporary folder and a throwaway UserDefaults suite,
//  never in the real Application Support, Caches or preferences.
//

import Testing
import Foundation
@testable import MacMate

/// A scratch Application Support / Caches pair and a throwaway defaults suite.
private struct Sandbox {
    let root: URL
    let applicationSupport: URL
    let caches: URL
    let suiteName: String
    let defaults: UserDefaults

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmate-freshinstall-\(UUID().uuidString)", isDirectory: true)
        applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        caches = root.appendingPathComponent("Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        suiteName = "com.example.macmate-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        // The suite leaves an empty plist behind; remove this suite's own file only.
        let plist = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    /// Stands in for what another application might have left on disk: an
    /// identity, pairings and caches that MacMate must neither use nor touch.
    @discardableResult
    func plantOtherAppData() throws -> [URL] {
        var planted: [URL] = []
        for app in ["Tether", "KDEConnect"] {
            let dir = applicationSupport.appendingPathComponent(app, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["identity.p12", "certificate.pem", "key.pem", "identity.pass"] {
                let file = dir.appendingPathComponent(name)
                try Data("\(app)-\(name)-original".utf8).write(to: file)
                planted.append(file)
            }
        }
        for name in ["TetherIncoming", "TetherAttachments", "TetherUpdate", "TetherOutgoing"] {
            let dir = caches.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("file.bin")
            try Data("\(name)-original".utf8).write(to: file)
            planted.append(file)
        }
        return planted
    }

    /// The other application's preference keys, planted in the throwaway suite.
    func plantOtherAppPreferences() {
        let pairing = (try? JSONEncoder().encode([
            PairedDevice(deviceId: "other-app-phone", deviceName: "Other App Phone",
                         deviceType: .phone, certificateFingerprint: "AA:BB", certificatePEM: nil)
        ])) ?? Data()
        defaults.set(pairing, forKey: "tether_paired_devices")
        defaults.set(pairing, forKey: "kdeconnect_paired_devices")
        defaults.set("tether-device-id", forKey: "tether_device_id")
        defaults.set("kdeconnect-device-id", forKey: "kdeconnect_device_id")
        defaults.set("Tether Mac", forKey: "tether_device_name")
        defaults.set(false, forKey: "tether_call_card")
        defaults.set(["10.9.9.9"], forKey: "tether_manual_peer_ips")
        defaults.set("10.9.9.8", forKey: "tether_last_peer_ip")
        defaults.set(["10.9.9.7": "tether-device-id"], forKey: "tether_host_owners")
    }

    /// Every file under `urls` with its bytes, to compare before and after.
    func snapshot(of urls: [URL]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: urls.map { ($0.path, (try? Data(contentsOf: $0)) ?? Data()) })
    }

    func children(of directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }
}

struct FreshInstallTests {

    // MARK: - Fresh-install defaults

    @Test func firstLaunchRegistersEveryDefaultSetting() {
        let box = Sandbox(); defer { box.cleanUp() }
        FreshInstall.prepare(defaults: box.defaults,
                             applicationSupportRoot: box.applicationSupport, cachesRoot: box.caches)

        // On by default
        for key in ["macmate_update_automatic", "macmate_files_enabled", "macmate_pause_media_during_calls",
                    "macmate_call_card", "macmate_tailscale_discovery"] {
            #expect(box.defaults.bool(forKey: key) == true, "\(key) should default on")
        }
        // Off by default: anything that sends or replaces something unasked
        for key in ["macmate_copy_codes_automatically", "macmate_lock_when_phone_leaves",
                    "macmate_reduce_motion", "macmate_share_wifi_ssid", "macmate_share_wallpaper",
                    "macmate_share_shortcuts"] {
            #expect(box.defaults.bool(forKey: key) == false, "\(key) should default off")
        }
        #expect(box.defaults.string(forKey: "macmate_sim_names") == "{}")
    }

    @Test func registeredKeysMatchTheKeysTheAppReads() {
        // FreshInstall lists keys as text; fail if one drifts from the owning type.
        let owners: [String: String] = [
            UpdateController.automaticKey: "update",
            PhoneFilesController.enabledKey: "files",
            CallMediaPauser.settingKey: "pause media",
            CallCard.settingKey: "call card",
            TailscaleDiscovery.enabledKey: "tailscale",
            OneTimeCode.autoCopyKey: "copy codes",
            AwayLock.settingKey: "away lock",
            MotionPreference.key: "motion",
            SettingsViewModel.shareWiFiSSIDKey: "wifi",
            SettingsViewModel.shareWallpaperKey: "wallpaper",
            RunCommandPlugin.shortcutsKey: "shortcuts",
            SIMNames.key: "sim names"
        ]
        #expect(Set(owners.keys) == Set(FreshInstall.defaultSettings.keys))
    }

    @Test func firstLaunchStartsWithNoPairedDevices() {
        let box = Sandbox(); defer { box.cleanUp() }
        let store = TrustStore(defaults: box.defaults)
        #expect(store.pairedDevices.isEmpty)
        // The empty registry is written under MacMate's own key, so it exists from launch one.
        #expect(box.defaults.data(forKey: TrustStore.userDefaultsKey) != nil)
    }

    @Test func firstLaunchStartsWithNoSavedAddresses() {
        let box = Sandbox(); defer { box.cleanUp() }
        let discovery = UDPDiscoveryService(defaults: box.defaults)
        #expect(discovery.persistedKnownTargets.isEmpty)
    }

    @Test func firstLaunchCreatesOnlyMacMateFolders() throws {
        let box = Sandbox(); defer { box.cleanUp() }
        FreshInstall.prepare(defaults: box.defaults,
                             applicationSupportRoot: box.applicationSupport, cachesRoot: box.caches)

        #expect(box.children(of: box.applicationSupport) == ["MacMate"])
        #expect(box.children(of: box.caches) == Set(AppIdentity.CacheFolder.allCases.map(\.rawValue)))

        let support = AppIdentity.applicationSupportDirectory(root: box.applicationSupport)
        let permissions = try FileManager.default.attributesOfItem(atPath: support.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    // MARK: - Independent identity and storage

    @Test func storageNamesBelongOnlyToMacMate() {
        #expect(AppIdentity.bundleIdentifier == "com.subhashh.MacMate")
        #expect(Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier,
                "the preferences domain is the bundle identifier")

        var names = [AppIdentity.storageDirectoryName, AppIdentity.preferenceKeyPrefix]
        names += AppIdentity.CacheFolder.allCases.map(\.rawValue)
        names += [AppIdentity.applicationSupportDirectory().path, AppIdentity.contactsDirectory().path,
                  AppIdentity.mountsDirectory().path, AppIdentity.finderMetadataDirectory().path]
        for name in names {
            #expect(!name.lowercased().contains("tether"), "\(name)")
            #expect(!name.lowercased().contains("kdeconnect"), "\(name)")
        }
        #expect(AppIdentity.applicationSupportDirectory().lastPathComponent == "MacMate")
        #expect(AppIdentity.CacheFolder.allCases.allSatisfy { $0.rawValue.hasPrefix("MacMate") })
    }

    @Test func everyDefaultSettingUsesMacMatesPrefix() {
        for key in FreshInstall.defaultSettings.keys {
            #expect(key.hasPrefix(AppIdentity.preferenceKeyPrefix), "\(key)")
        }
        #expect(DeviceIdentity.deviceIdKey.hasPrefix(AppIdentity.preferenceKeyPrefix))
        #expect(DeviceIdentity.deviceNameKey.hasPrefix(AppIdentity.preferenceKeyPrefix))
        #expect(TrustStore.userDefaultsKey.hasPrefix(AppIdentity.preferenceKeyPrefix))
    }

    @Test func freshInstallWritesNothingButMacMateKeys() {
        let box = Sandbox(); defer { box.cleanUp() }
        FreshInstall.prepare(defaults: box.defaults,
                             applicationSupportRoot: box.applicationSupport, cachesRoot: box.caches)
        _ = TrustStore(defaults: box.defaults)
        let discovery = UDPDiscoveryService(defaults: box.defaults)
        discovery.addKnownTarget(ip: "192.168.1.50")
        _ = discovery.persistedKnownTargets   // waits for the write

        let written = Set(box.defaults.persistentDomain(forName: box.suiteName)?.keys.map { $0 } ?? [])
        #expect(!written.isEmpty)
        for key in written {
            #expect(key.hasPrefix(AppIdentity.preferenceKeyPrefix), "unexpected key \(key)")
        }
    }

    // MARK: - No legacy migration, and legacy data left alone

    @Test func otherAppsPreferencesAreNeitherReadNorModified() throws {
        let box = Sandbox(); defer { box.cleanUp() }
        box.plantOtherAppPreferences()
        let before = box.defaults.persistentDomain(forName: box.suiteName) ?? [:]

        FreshInstall.prepare(defaults: box.defaults,
                             applicationSupportRoot: box.applicationSupport, cachesRoot: box.caches)

        // Nothing inherited: pairings, addresses and the call-card choice start fresh.
        #expect(TrustStore(defaults: box.defaults).pairedDevices.isEmpty)
        #expect(UDPDiscoveryService(defaults: box.defaults).persistedKnownTargets.isEmpty)
        #expect(box.defaults.bool(forKey: "macmate_call_card") == true,
                "tether_call_card = false must not carry over")

        // And nothing of theirs was changed or removed.
        let after = box.defaults.persistentDomain(forName: box.suiteName) ?? [:]
        for (key, value) in before {
            #expect((after[key] as? NSObject) == (value as? NSObject), "\(key) was modified")
        }
    }

    @Test func otherAppsFilesAreNeitherReadNorModified() throws {
        let box = Sandbox(); defer { box.cleanUp() }
        let planted = try box.plantOtherAppData()
        let before = box.snapshot(of: planted)

        FreshInstall.prepare(defaults: box.defaults,
                             applicationSupportRoot: box.applicationSupport, cachesRoot: box.caches)
        _ = DeviceIdentity(applicationSupportRoot: box.applicationSupport, defaults: box.defaults)

        #expect(box.snapshot(of: planted) == before, "another app's files changed")
        #expect(box.children(of: box.applicationSupport) == ["Tether", "KDEConnect", "MacMate"])
        for dir in ["Tether", "KDEConnect"] {
            #expect(box.children(of: box.applicationSupport.appendingPathComponent(dir))
                    == ["identity.p12", "certificate.pem", "key.pem", "identity.pass"],
                    "\(dir) gained or lost a file")
        }
        for name in ["TetherIncoming", "TetherAttachments", "TetherUpdate", "TetherOutgoing"] {
            #expect(box.children(of: box.caches.appendingPathComponent(name)) == ["file.bin"], "\(name)")
        }
    }

    @Test func identityIsCreatedFreshNotImportedFromAnotherApp() throws {
        let box = Sandbox(); defer { box.cleanUp() }
        try box.plantOtherAppData()
        box.plantOtherAppPreferences()

        let identity = DeviceIdentity(applicationSupportRoot: box.applicationSupport, defaults: box.defaults)

        #expect(identity.deviceId != "tether-device-id")
        #expect(identity.deviceId != "kdeconnect-device-id")
        #expect(identity.deviceName != "Tether Mac")
        #expect(!identity.certificateFingerprint.isEmpty)

        // Its key material is its own, inside MacMate's folder.
        let support = AppIdentity.applicationSupportDirectory(root: box.applicationSupport)
        #expect(box.children(of: support).isSuperset(of: ["identity.p12", "certificate.pem", "key.pem", "identity.pass"]))
        let ownPEM = try String(contentsOf: support.appendingPathComponent("certificate.pem"), encoding: .utf8)
        #expect(!ownPEM.contains("original"))
        #expect(box.defaults.string(forKey: DeviceIdentity.deviceIdKey) == identity.deviceId)
    }

    // MARK: - Subsequent launches

    @Test func laterLaunchesKeepTheIdentitySettingsAndPairings() throws {
        let box = Sandbox(); defer { box.cleanUp() }

        FreshInstall.prepare(defaults: box.defaults,
                             applicationSupportRoot: box.applicationSupport, cachesRoot: box.caches)
        let first = DeviceIdentity(applicationSupportRoot: box.applicationSupport, defaults: box.defaults)
        box.defaults.set(false, forKey: "macmate_call_card")                    // the user changes a setting
        let store = TrustStore(defaults: box.defaults)
        store.add(device: PairedDevice(deviceId: "my-phone", deviceName: "My Phone", deviceType: .phone,
                                       certificateFingerprint: "11:22", certificatePEM: nil))

        // Second launch.
        FreshInstall.prepare(defaults: box.defaults,
                             applicationSupportRoot: box.applicationSupport, cachesRoot: box.caches)
        let second = DeviceIdentity(applicationSupportRoot: box.applicationSupport, defaults: box.defaults)

        #expect(second.deviceId == first.deviceId)
        #expect(second.certificateFingerprint == first.certificateFingerprint)
        #expect(box.defaults.bool(forKey: "macmate_call_card") == false, "a saved choice is never reset")
        #expect(TrustStore(defaults: box.defaults).pairedDevices.keys.contains("my-phone"))
        #expect(box.children(of: box.applicationSupport) == ["MacMate"])
    }

    @Test func pairingsAndAddressesAreSavedUnderMacMateKeysOnly() {
        let box = Sandbox(); defer { box.cleanUp() }
        let store = TrustStore(defaults: box.defaults)
        store.add(device: PairedDevice(deviceId: "p", deviceName: "P", deviceType: .phone,
                                       certificateFingerprint: "00", certificatePEM: nil))
        let discovery = UDPDiscoveryService(defaults: box.defaults)
        discovery.noteHost("192.168.1.9", belongsTo: "p")
        discovery.addKnownTarget(ip: "192.168.1.9")
        _ = discovery.persistedKnownTargets

        let keys = Set(box.defaults.persistentDomain(forName: box.suiteName)?.keys.map { $0 } ?? [])
        #expect(keys.isSuperset(of: ["macmate_paired_devices", "macmate_manual_peer_ips", "macmate_host_owners"]))
        #expect(!keys.contains { $0.hasPrefix("tether_") || $0.hasPrefix("kdeconnect_") })
    }

    // MARK: - Guard: the source must not reintroduce migration

    /// Fails if code that reads, copies or deletes another application's data
    /// (its preference keys, folders, bundle identifiers or pasteboards) comes back.
    @Test func sourceContainsNoLegacyStorageOrMigrationCode() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoots = ["MacMate", "MacMateShare"].map { repository.appendingPathComponent($0) }
        guard sourceRoots.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return   // running without the source tree (for example on another machine)
        }

        let forbidden = [
            #"tether_"#,                           // another app's preference keys
            #"TETHER_"#,                           // its environment variables and identifiers
            #"com\.subhashh\.tether"#,             // its bundle id, domain, pasteboards
            #"kdeconnect_(device|name|paired)"#,   // KDE Connect's saved identity and pairings
            #"suiteName:"#,                        // reading another preference domain
            #"Support/(Tether|KDEConnect)"#,       // another app's Application Support folder
            #""(Tether|KDEConnect)""#,             // ...or naming it directly
            #"Tether(Incoming|Attachments|Update|Outgoing|ADBReads|NFS)"#
        ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

        var offenders: [String] = []
        for root in sourceRoots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if forbidden.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                        offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "legacy storage references found:\n\(offenders.joined(separator: "\n"))")
    }
}
