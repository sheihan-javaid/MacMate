//
//  ShareInbox.swift
//  MacMate
//
//  Receives what the Share-menu extension hands over and sends it to
//  the connected phone. The writing side is MacMateShare/ShareHandoff.swift;
//  the names below must match it.
//

import AppKit
import UserNotifications

@MainActor
final class ShareInbox {
    static let shared = ShareInbox()

    private static let pasteboardName = NSPasteboard.Name("com.subhashh.MacMate.share")

    /// Connected devices, published for the extension's "Send to" chooser.
    private static let devicesPasteboardName = NSPasteboard.Name("com.subhashh.MacMate.devices")

    private static let notificationName = Notification.Name("com.subhashh.MacMate.shareRequest")

    /// Items older than this are ignored, so a stale hand-off is never replayed.
    private static let maximumAge: TimeInterval = 120

    private enum Key {
        static let kind = NSPasteboard.PasteboardType("com.subhashh.macmate.kind")
        static let created = NSPasteboard.PasteboardType("com.subhashh.macmate.created")
        static let path = NSPasteboard.PasteboardType("com.subhashh.macmate.path")
        static let data = NSPasteboard.PasteboardType("com.subhashh.macmate.data")
        static let name = NSPasteboard.PasteboardType("com.subhashh.macmate.name")
        static let value = NSPasteboard.PasteboardType("com.subhashh.macmate.value")
        static let device = NSPasteboard.PasteboardType("com.subhashh.macmate.device")
        static let devices = NSPasteboard.PasteboardType("com.subhashh.macmate.devices")

    }

    private var observers: [NSObjectProtocol] = []
    private var publishedDevices: [[String: String]]?

    /// Lets the Share extension offer a choice when more than one device is
    /// connected. Only names, IDs and symbols; nothing sensitive.
    func publishConnectedDevices(_ devices: [DeviceViewModel]) {
        let list = devices.map { ["id": $0.id, "name": $0.name, "symbol": $0.deviceType.systemImageName] }
        guard list != publishedDevices,
              let json = try? JSONSerialization.data(withJSONObject: list) else { return }
        publishedDevices = list

        let pasteboard = NSPasteboard(name: Self.devicesPasteboardName)
        pasteboard.clearContents()
        pasteboard.setData(json, forType: Key.devices)
    }

    /// Shared data (e.g. photos) is written here before sending.
    private var outgoingDirectory: URL {
        AppIdentity.cacheFolder(.outgoing)
    }

    func start() {
        guard observers.isEmpty else { return }
        removeOldOutgoingFiles()

        let center = DistributedNotificationCenter.default()
        let handler: (Notification) -> Void = { _ in
            Task { @MainActor in ShareInbox.shared.drain() }
        }

        observers.append(center.addObserver(forName: Self.notificationName, object: nil, queue: .main, using: handler))

        // The extension launches MacMate when it isn't running; pick up what it left.
        // Give discovery a moment so a known phone has reconnected first.
        Task {
            try? await Task.sleep(for: .seconds(4))
            drain()
        }
    }

    private func drain() {
        let activePasteboard = NSPasteboard(name: Self.pasteboardName)
        let items = activePasteboard.pasteboardItems ?? []

        guard !items.isEmpty else { return }
        // Items are read lazily from the pasteboard server, so copy every value
        // out before clearing; after clearContents() they all read as nil.
        let entries = items.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        activePasteboard.clearContents()

        var files: [URL] = []
        var links: [URL] = []
        var texts: [String] = []
        var skippedFolders = 0
        var chosenDeviceId: String?
        let now = Date().timeIntervalSince1970

        for item in entries {
            func string(_ keys: [NSPasteboard.PasteboardType]) -> String? {
                for key in keys {
                    if let data = item[key], let str = String(data: data, encoding: .utf8) {
                        return str
                    }
                }
                return nil
            }
            guard let createdStr = string([Key.created]),
                  let created = Double(createdStr),
                  now - created < Self.maximumAge,
                  let kind = string([Key.kind]) else { continue }
            chosenDeviceId = chosenDeviceId ?? string([Key.device])

            switch kind {
            case "file":
                guard let path = string([Key.path]) else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    skippedFolders += 1
                } else {
                    files.append(URL(fileURLWithPath: path))
                }
            case "data":
                let data = item[Key.data]
                let name = string([Key.name]) ?? "Shared"
                if let data, let url = writeOutgoing(data, name: name) {
                    files.append(url)
                }
            case "url":
                if let urlString = string([Key.value]),
                   let url = URL(string: urlString),
                   ["http", "https"].contains(url.scheme?.lowercased()) {
                    links.append(url)
                }
            case "text":
                if let text = string([Key.value]), !text.isEmpty {
                    texts.append(text)
                }
            default:
                continue
            }
        }

        let total = files.count + links.count + texts.count
        guard total > 0 else {
            MacMateLog("[ShareInbox] Nothing sendable in \(entries.count) shared item(s)")
            if skippedFolders > 0 {
                notify(title: "Folders can't be sent", body: "MacMate sends files, not folders. Select the files inside instead.")
            }
            return
        }

        let model = MacMateAppModel.shared
        let device: DeviceViewModel
        if let chosenDeviceId {
            // Picked in the extension's chooser; it may have disconnected since.
            guard let chosen = model.connectedDevices.first(where: { $0.id == chosenDeviceId }) else {
                notify(title: "Device disconnected", body: "The device you chose is no longer connected. Share again to pick another.")
                return
            }
            device = chosen
        } else if let primary = model.primaryDevice {
            device = primary
        } else {
            notify(title: "No phone connected", body: "Open KDE Connect on your phone, then share again.")
            return
        }

        MacMateLog("[ShareInbox] Sending \(files.count) file(s), \(links.count) link(s), \(texts.count) text(s) to \(device.name)")
        if !files.isEmpty { device.sendFiles(files) }
        for link in links { MacMateService.shared.sendURL(link, to: device.id) }
        for text in texts { MacMateService.shared.sendText(text, to: device.id) }

        notify(title: "Sending to \(device.name)", body: summary(files: files, links: links.count, texts: texts.count, skippedFolders: skippedFolders))
    }

    private func summary(files: [URL], links: Int, texts: Int, skippedFolders: Int) -> String {
        var parts: [String] = []
        if files.count == 1 { parts.append(files[0].lastPathComponent) }
        if files.count > 1 { parts.append("\(files.count) files") }
        if links > 0 { parts.append(links == 1 ? "a link" : "\(links) links") }
        if texts > 0 { parts.append(texts == 1 ? "some text" : "\(texts) texts") }
        var body = parts.formatted(.list(type: .and))
        if skippedFolders > 0 { body += ". Folders were skipped." }
        return body
    }

    private func writeOutgoing(_ data: Data, name: String) -> URL? {
        let directory = outgoingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = SafeFilename.uniqueURL(in: directory, for: name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            MacMateLog("[ShareInbox] Could not stage shared data: \(error)")
            return nil
        }
    }

    /// Staged copies are only needed until they're sent; clear out old ones.
    private func removeOldOutgoingFiles() {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: outgoingDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
