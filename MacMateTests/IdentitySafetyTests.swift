//
//  IdentitySafetyTests.swift
//  MacMateTests
//
//  An identity on disk is what every paired phone trusts, so startup must reuse
//  it, recover what it can, and set anything unusable aside by renaming. It must
//  never overwrite or delete it. Everything here uses temporary folders and
//  throwaway keys; no real identity is read or written.
//

import Testing
import Foundation
@testable import MacMate

private struct IdentitySandbox {
    let root: URL
    let support: URL
    let suiteName = "com.example.macmate-identity-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmate-identity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        support = AppIdentity.applicationSupportDirectory(root: root)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        let plist = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    func start() -> DeviceIdentity {
        DeviceIdentity(applicationSupportRoot: root, defaults: defaults)
    }

    func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? [])
    }

    func bytes(_ name: String) -> Data? { try? Data(contentsOf: support.appendingPathComponent(name)) }

    /// Files whose names say they were set aside.
    func setAside() -> [String] { names().filter { $0.contains(".broken-") }.sorted() }
}

struct IdentitySafetyTests {
    private static let files = ["identity.p12", "identity.pass", "key.pem", "certificate.pem"]

    @Test func lostDeviceIdIsRecoveredNotRegenerated() {
        let box = IdentitySandbox(); defer { box.cleanUp() }
        let first = box.start()
        let before = Self.files.map { box.bytes($0) }

        // The preferences reset (or were restored without the device ID); the key files are intact.
        box.defaults.removeObject(forKey: DeviceIdentity.deviceIdKey)
        let second = box.start()

        #expect(second.deviceId == first.deviceId, "the ID comes back from the certificate")
        #expect(second.certificateFingerprint == first.certificateFingerprint)
        #expect(Self.files.map { box.bytes($0) } == before, "no identity file was rewritten")
        #expect(box.setAside().isEmpty)
        #expect(box.defaults.string(forKey: DeviceIdentity.deviceIdKey) == first.deviceId)
    }

    @Test func intactIdentityIsLeftUntouchedOnEveryLaunch() {
        let box = IdentitySandbox(); defer { box.cleanUp() }
        let first = box.start()
        let before = Self.files.map { box.bytes($0) }
        for _ in 0..<3 {
            let again = box.start()
            #expect(again.deviceId == first.deviceId)
            #expect(again.certificateFingerprint == first.certificateFingerprint)
        }
        #expect(Self.files.map { box.bytes($0) } == before)
        #expect(box.setAside().isEmpty)
    }

    @Test func partialIdentityFilesAreSetAsideNotOverwritten() throws {
        let box = IdentitySandbox(); defer { box.cleanUp() }
        // A key and certificate without their bundle (for example a half-restored backup).
        try FileManager.default.createDirectory(at: box.support, withIntermediateDirectories: true)
        let original = Data("original key bytes".utf8)
        try original.write(to: box.support.appendingPathComponent("key.pem"))
        try Data("original cert bytes".utf8).write(to: box.support.appendingPathComponent("certificate.pem"))

        let identity = box.start()

        let aside = box.setAside()
        #expect(aside.count == 2, "both files were set aside")
        let keyCopy = try #require(aside.first { $0.hasPrefix("key.pem.broken-") })
        #expect(box.bytes(keyCopy) == original, "the original bytes are preserved")
        #expect(!identity.deviceId.isEmpty)
        #expect(box.bytes("key.pem") != original, "a new identity was written to the usual names")
    }

    @Test func unreadableBundleIsSetAsideNotOverwritten() throws {
        let box = IdentitySandbox(); defer { box.cleanUp() }
        let first = box.start()

        let corrupt = Data("not a pkcs12 bundle".utf8)
        try corrupt.write(to: box.support.appendingPathComponent("identity.p12"))
        let originalKey = box.bytes("key.pem")

        let second = box.start()

        #expect(second.deviceId != first.deviceId, "a corrupt bundle can't be reused")
        let aside = box.setAside()
        #expect(aside.contains { $0.hasPrefix("identity.p12.broken-") })
        let keyCopy = try #require(aside.first { $0.hasPrefix("key.pem.broken-") })
        #expect(box.bytes(keyCopy) == originalKey, "the previous private key file was kept, renamed")
    }

    @Test func settingAsideTwiceNeverCollides() throws {
        let box = IdentitySandbox(); defer { box.cleanUp() }
        _ = box.start()
        try Data("garbage one".utf8).write(to: box.support.appendingPathComponent("identity.p12"))
        _ = box.start()
        try Data("garbage two".utf8).write(to: box.support.appendingPathComponent("identity.p12"))
        _ = box.start()

        let bundles = box.setAside().filter { $0.hasPrefix("identity.p12.broken-") }
        #expect(bundles.count == 2, "each set-aside copy has its own name: \(bundles)")
        let contents = Set(bundles.compactMap { box.bytes($0) })
        #expect(contents == [Data("garbage one".utf8), Data("garbage two".utf8)])
    }

    @Test func identityAndDeviceIdLiveOutsideTheAppBundle() {
        #expect(!AppIdentity.applicationSupportDirectory().path.hasPrefix(Bundle.main.bundleURL.path),
                "replacing the app can't touch the identity")
        #expect(AppIdentity.applicationSupportDirectory().path.contains("/Library/Application Support/MacMate"))
        #expect(DeviceIdentity.deviceIdKey == "macmate_device_id")      // saved in the preferences domain
        #expect(TrustStore.userDefaultsKey == "macmate_paired_devices") // pairings: same domain, not the folder
    }
}
