//
//  ShareHandoff.swift
//  MacMateShare
//
//  Writing side of the Share-menu hand-off. The reading side is
//  MacMate/Services/ShareInbox.swift; the names below must match it.
//

import AppKit

enum ShareHandoff {
    static let pasteboardName = NSPasteboard.Name("com.subhashh.MacMate.share")
    static let legacyPasteboardName = NSPasteboard.Name("com.subhashh.Tether.share")

    static let devicesPasteboardName = NSPasteboard.Name("com.subhashh.MacMate.devices")
    static let legacyDevicesPasteboardName = NSPasteboard.Name("com.subhashh.Tether.devices")

    static let notificationName = Notification.Name("com.subhashh.MacMate.shareRequest")
    static let legacyNotificationName = Notification.Name("com.subhashh.Tether.shareRequest")

    static let appBundleIdentifiers = ["com.subhashh.MacMate", "com.subhashh.Tether"]

    enum Kind: String { case file, data, url, text }

    enum Key {
        static let kind = NSPasteboard.PasteboardType("com.subhashh.macmate.kind")
        static let created = NSPasteboard.PasteboardType("com.subhashh.macmate.created")
        static let path = NSPasteboard.PasteboardType("com.subhashh.macmate.path")
        static let data = NSPasteboard.PasteboardType("com.subhashh.macmate.data")
        static let name = NSPasteboard.PasteboardType("com.subhashh.macmate.name")
        static let value = NSPasteboard.PasteboardType("com.subhashh.macmate.value")
        static let device = NSPasteboard.PasteboardType("com.subhashh.macmate.device")
        static let devices = NSPasteboard.PasteboardType("com.subhashh.macmate.devices")

        static let legacyKind = NSPasteboard.PasteboardType("com.subhashh.tether.kind")
        static let legacyCreated = NSPasteboard.PasteboardType("com.subhashh.tether.created")
        static let legacyPath = NSPasteboard.PasteboardType("com.subhashh.tether.path")
        static let legacyData = NSPasteboard.PasteboardType("com.subhashh.tether.data")
        static let legacyName = NSPasteboard.PasteboardType("com.subhashh.tether.name")
        static let legacyValue = NSPasteboard.PasteboardType("com.subhashh.tether.value")
        static let legacyDevice = NSPasteboard.PasteboardType("com.subhashh.tether.device")
        static let legacyDevices = NSPasteboard.PasteboardType("com.subhashh.tether.devices")
    }

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let symbol: String
    }

    /// Devices connected to a running MacMate, as it last published them.
    /// Empty when MacMate isn't running, since the list could be stale.
    static func connectedDevices() -> [Device] {
        let isRunning = appBundleIdentifiers.contains { id in
            !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        }
        guard isRunning else { return [] }

        let data = NSPasteboard(name: devicesPasteboardName).data(forType: Key.devices)
            ?? NSPasteboard(name: legacyDevicesPasteboardName).data(forType: Key.legacyDevices)
        guard let data,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["id"], let name = entry["name"] else { return nil }
            return Device(id: id, name: name, symbol: entry["symbol"] ?? "iphone")
        }
    }

    enum Entry {
        case file(path: String)
        case data(Data, name: String)
        case url(String)
        case text(String)
    }

    /// - Parameter deviceId: the device chosen in the extension, or nil to let
    ///   MacMate use its current device.
    static func write(_ entries: [Entry], deviceId: String?) {
        let created = String(Date().timeIntervalSince1970)
        let items = entries.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(created, forType: Key.created)
            item.setString(created, forType: Key.legacyCreated)
            if let deviceId {
                item.setString(deviceId, forType: Key.device)
                item.setString(deviceId, forType: Key.legacyDevice)
            }
            switch entry {
            case .file(let path):
                item.setString(Kind.file.rawValue, forType: Key.kind)
                item.setString(path, forType: Key.path)
                item.setString(Kind.file.rawValue, forType: Key.legacyKind)
                item.setString(path, forType: Key.legacyPath)
            case .data(let data, let name):
                item.setString(Kind.data.rawValue, forType: Key.kind)
                item.setData(data, forType: Key.data)
                item.setString(name, forType: Key.name)
                item.setString(Kind.data.rawValue, forType: Key.legacyKind)
                item.setData(data, forType: Key.legacyData)
                item.setString(name, forType: Key.legacyName)
            case .url(let url):
                item.setString(Kind.url.rawValue, forType: Key.kind)
                item.setString(url, forType: Key.value)
                item.setString(Kind.url.rawValue, forType: Key.legacyKind)
                item.setString(url, forType: Key.legacyValue)
            case .text(let text):
                item.setString(Kind.text.rawValue, forType: Key.kind)
                item.setString(text, forType: Key.value)
                item.setString(Kind.text.rawValue, forType: Key.legacyKind)
                item.setString(text, forType: Key.legacyValue)
            }
            return item
        }

        // Write to both primary and legacy pasteboards for smooth compatibility
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        pasteboard.writeObjects(items)

        let legacyPasteboard = NSPasteboard(name: legacyPasteboardName)
        legacyPasteboard.clearContents()
        legacyPasteboard.writeObjects(items)
    }

    /// Tells a running MacMate to pick up the items, or launches it to do so.
    static func deliver(appURL: URL) {
        let isRunning = appBundleIdentifiers.contains { id in
            !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        }
        if !isRunning {
            // MacMate reads the pasteboard when it finishes launching.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } else {
            DistributedNotificationCenter.default().postNotificationName(
                notificationName, object: nil, userInfo: nil, deliverImmediately: true
            )
            DistributedNotificationCenter.default().postNotificationName(
                legacyNotificationName, object: nil, userInfo: nil, deliverImmediately: true
            )
        }
    }
}
