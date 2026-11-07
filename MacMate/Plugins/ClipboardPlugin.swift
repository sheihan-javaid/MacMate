//
//  ClipboardPlugin.swift
//  MacMate
//

import AppKit
import Foundation
import Combine

public final class ClipboardPlugin: MacMatePlugin, @unchecked Sendable {
    public let supportedPacketTypes = [
        "kdeconnect.clipboard",
        "kdeconnect.clipboard.connect"
    ]

    private var lastChangeCount: Int = 0
    private var lastReceivedContent: String = ""
    private var lastSentContent: String = ""
    private var lastLocalClipboardTimestamp: Int64 = 0
    private var timer: Timer?
    private var connectedDevices: [DeviceConnection] = []
    private var pairedDevicesObserver: AnyCancellable?
    private let lock = NSLock()

    public init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
        if let initial = NSPasteboard.general.string(forType: .string), !initial.isEmpty {
            self.lastSentContent = initial
        }
        setupTrustStoreObserver()
    }

    private func setupTrustStoreObserver() {
        pairedDevicesObserver = TrustStore.shared.$pairedDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateMonitoringLifecycle()
            }
    }

    private func evaluateMonitoringLifecycle() {
        let hasSyncEnabledDevice: Bool = lock.withLock {
            connectedDevices.contains { conn in
                guard let deviceId = conn.peerDeviceInfo?.deviceId,
                      let paired = TrustStore.shared.pairedDevice(for: deviceId) else {
                    return false
                }
                return paired.isClipboardSyncEnabled
            }
        }

        if hasSyncEnabledDevice {
            startMonitoringIfNeeded()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoringIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.timer == nil else { return }
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkPasteboard()
            }
        }
    }

    private func stopMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private func checkPasteboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }

        // Suppress echo if this content originated from remote device or was already sent
        if text == lastReceivedContent || text == lastSentContent {
            return
        }

        lastSentContent = text
        lastLocalClipboardTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        MacMateLog("[ClipboardPlugin] Local clipboard changed (\(text.count) characters). Broadcasting to paired devices")
        broadcastClipboard(content: text)
    }

    public func onConnected(connection: DeviceConnection) {
        lock.withLock {
            let deviceId = connection.peerDeviceInfo?.deviceId
            connectedDevices.removeAll { $0.peerDeviceInfo?.deviceId == deviceId }
            connectedDevices.append(connection)
        }
        evaluateMonitoringLifecycle()
    }

    public func onDisconnected(connection: DeviceConnection) {
        lock.withLock {
            connectedDevices.removeAll { $0 === connection }
        }
        evaluateMonitoringLifecycle()
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.clipboard" || packet.type == "kdeconnect.clipboard.connect" else { return }

        guard let deviceId = connection.peerDeviceInfo?.deviceId,
              let paired = TrustStore.shared.pairedDevice(for: deviceId),
              paired.isClipboardSyncEnabled else {
            return
        }

        guard let content = packet.string(for: "content") else { return }

        // If it's a connect packet, verify timestamp to prevent overwriting with stale content
        if packet.type == "kdeconnect.clipboard.connect" {
            let packetTime = packet.int64(for: "timestamp", default: 0)
            if packetTime > 0 && packetTime < lastLocalClipboardTimestamp {
                MacMateLog("[ClipboardPlugin] Ignoring connect packet with older timestamp: \(packetTime) vs \(lastLocalClipboardTimestamp)")
                return
            }
        }

        guard content != lastReceivedContent && content != lastSentContent else { return }

        lastReceivedContent = content
        lastSentContent = content
        if packet.type == "kdeconnect.clipboard.connect" {
            let packetTime = packet.int64(for: "timestamp", default: 0)
            if packetTime > 0 {
                lastLocalClipboardTimestamp = packetTime
            }
        } else {
            lastLocalClipboardTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        }

        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            self.lastChangeCount = NSPasteboard.general.changeCount
            MacMateLog("[ClipboardPlugin] Synced clipboard from \(connection.peerDeviceInfo?.deviceName ?? "Device") (\(content.count) characters)")
        }
    }

    public func broadcastClipboard(content: String, targetDeviceId: String? = nil) {
        let packet = NetworkPacket(
            type: "kdeconnect.clipboard",
            body: ["content": content]
        )
        let targets: [DeviceConnection] = lock.withLock { connectedDevices }
        for connection in targets {
            guard let deviceId = connection.peerDeviceInfo?.deviceId else { continue }
            if let target = targetDeviceId {
                if deviceId == target {
                    connection.send(packet: packet)
                }
            } else if let paired = TrustStore.shared.pairedDevice(for: deviceId),
                      paired.isClipboardSyncEnabled {
                connection.send(packet: packet)
            }
        }
    }
}
