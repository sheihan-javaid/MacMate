//
//  AppIdentity.swift
//  MacMate
//

import Foundation

/// The names under which MacMate stores its own data.
///
/// MacMate is an independent application: a fresh install starts with its own
/// preferences, identity and folders, and never reads, copies or removes data
/// that belongs to another application, including the projects it descends
/// from. Every location is derived from the names below, so there is one place
/// to check that.
nonisolated enum AppIdentity {
    /// Also the name of the preferences domain (`UserDefaults.standard` in the app).
    static let bundleIdentifier = "com.subhashh.MacMate"
    /// Folder under Application Support, and the prefix of MacMate's cache folders.
    static let storageDirectoryName = "MacMate"
    /// Every preference key MacMate writes starts with this.
    static let preferenceKeyPrefix = "macmate_"

    /// Folders MacMate creates under Caches.
    enum CacheFolder: String, CaseIterable {
        case incoming = "MacMateIncoming"
        case attachments = "MacMateAttachments"
        case outgoing = "MacMateOutgoing"
        case update = "MacMateUpdate"
    }

    /// ~/Library/Application Support
    static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// ~/Library/Caches
    static func cachesRoot(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// MacMate's own folder, e.g. ~/Library/Application Support/MacMate.
    static func applicationSupportDirectory(root: URL? = nil) -> URL {
        (root ?? applicationSupportRoot()).appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    static func cacheFolder(_ folder: CacheFolder, cachesRoot: URL? = nil) -> URL {
        (cachesRoot ?? Self.cachesRoot()).appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    static func contactsDirectory(root: URL? = nil) -> URL {
        applicationSupportDirectory(root: root).appendingPathComponent("Contacts", isDirectory: true)
    }

    static func mountsDirectory(root: URL? = nil) -> URL {
        applicationSupportDirectory(root: root).appendingPathComponent("Mounts", isDirectory: true)
    }

    static func finderMetadataDirectory(root: URL? = nil) -> URL {
        applicationSupportDirectory(root: root).appendingPathComponent("Finder Metadata", isDirectory: true)
    }
}

/// Sets up a first launch deterministically: the same default settings and
/// folders every time, with nothing carried over from any other application.
nonisolated enum FreshInstall {
    /// Every setting's value until the user changes it. Registered with
    /// `UserDefaults`, which only supplies them when no value is saved.
    static let defaultSettings: [String: Any] = [
        "macmate_update_automatic": true,
        "macmate_files_enabled": true,
        "macmate_pause_media_during_calls": true,
        "macmate_call_card": true,
        "macmate_tailscale_discovery": true,
        "macmate_copy_codes_automatically": false,
        "macmate_lock_when_phone_leaves": false,
        "macmate_reduce_motion": false,
        "macmate_share_wifi_ssid": false,
        "macmate_share_wallpaper": false,
        "macmate_share_shortcuts": false,
        "macmate_sim_names": "{}"
    ]

    /// Registers default settings and creates MacMate's own folders.
    /// Safe to run on every launch; it never changes a saved value or touches
    /// anything outside MacMate's own names.
    static func prepare(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        applicationSupportRoot: URL? = nil,
        cachesRoot: URL? = nil
    ) {
        defaults.register(defaults: defaultSettings)

        let support = AppIdentity.applicationSupportDirectory(root: applicationSupportRoot)
        try? fileManager.createDirectory(
            at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        for folder in AppIdentity.CacheFolder.allCases {
            try? fileManager.createDirectory(
                at: AppIdentity.cacheFolder(folder, cachesRoot: cachesRoot),
                withIntermediateDirectories: true)
        }
    }
}
