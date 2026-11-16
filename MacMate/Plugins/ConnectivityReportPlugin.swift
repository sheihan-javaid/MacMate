//
//  ConnectivityReportPlugin.swift
//  MacMate
//

import Foundation
import Combine

/// Cellular network type and signal strength reported by the phone.
public struct SignalStrength: Sendable, Equatable {
    public let networkType: String
    /// 0...4, as reported by the peer.
    public let strength: Int

    public init(networkType: String, strength: Int) {
        self.networkType = networkType
        self.strength = strength
    }

    /// Short label for the menu bar, e.g. "LTE" or "5G".
    public var shortLabel: String {
        networkType.isEmpty || networkType == "Unknown" ? "Cellular" : networkType
    }
}

/// Tracks the phone's cellular connectivity and, when enabled, shares this Mac's
/// Wi-Fi SSID with paired devices.
///
/// The peer sends `kdeconnect.connectivity_report` with a `signalStrengths` object
/// keyed by SIM subscription id, each holding `networkType` and `signalStrength`.
/// It may also carry a top-level `ssid` string naming the phone's WiFi network.
///
/// When `shouldSendSSID` is true, this Mac also emits `kdeconnect.connectivity_report`
/// with its own `ssid` so peers can display the Mac's network name.
public final class ConnectivityReportPlugin: ObservableObject, MacMatePlugin, WiFiSSIDMonitorDelegate, @unchecked Sendable {

    public let supportedPacketTypes = ["kdeconnect.connectivity_report"]

    /// Reported signal per device, keyed by device id. A device can have several
    /// subscriptions (dual SIM), so the value is the strongest one.
    @Published public private(set) var signalStrength: [String: SignalStrength] = [:]
    /// Each SIM's signal per device, keyed by subscription id.
    @Published public private(set) var subscriptions: [String: [Int64: SignalStrength]] = [:]
    /// The phone's WiFi SSID per device, keyed by device id. Empty/invalid values are removed.
    @Published public private(set) var wifiSSID: [String: String] = [:]

    /// Injectible provider for the Mac's own WiFi SSID (CoreWLAN in production, mock in tests).
    public var ssidProvider: WiFiSSIDProvider = CoreWLANSSIDProvider()
    /// When true, this Mac sends its SSID to connected peers. Set by MacMateService
    /// based on the user setting. Defaults to false.
    public var shouldSendSSID: Bool = false

    /// Active connections keyed by device id, used to push SSID updates.
    internal var activeConnections: [String: DeviceConnection] = [:]

    public init() {}

    public func onConnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        activeConnections[deviceId] = connection
        if shouldSendSSID {
            if let ssid = ssidProvider.currentSSID().flatMap(sanitizeSsid) {
                sendSSID(ssid, to: connection)
            } else {
                MacMateLog("[ConnectivityReportPlugin] shouldSendSSID is true on connect, but currentSSID() returned nil (check macOS Location Services permission)")
            }
        }
    }

    public func onDisconnected(connection: DeviceConnection) {
        guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
        activeConnections.removeValue(forKey: deviceId)
        signalStrength.removeValue(forKey: deviceId)
        subscriptions.removeValue(forKey: deviceId)
        wifiSSID.removeValue(forKey: deviceId)
    }

    /// Sends this Mac's WiFi SSID to all connected peers.
    public func broadcastSSID() {
        guard shouldSendSSID else {
            MacMateLog("[ConnectivityReportPlugin] broadcastSSID skipped: shouldSendSSID is false")
            return
        }
        guard let ssid = ssidProvider.currentSSID().flatMap(sanitizeSsid) else {
            MacMateLog("[ConnectivityReportPlugin] broadcastSSID skipped: currentSSID() returned nil (check macOS Location Services permission)")
            return
        }
        for connection in activeConnections.values {
            sendSSID(ssid, to: connection)
        }
    }

    private func sendSSID(_ ssid: String, to connection: DeviceConnection) {
        MacMateLog("[ConnectivityReportPlugin] Sending Wi-Fi SSID to \(connection.peerDeviceInfo?.deviceName ?? "device")")
        let packet = NetworkPacket(type: "kdeconnect.connectivity_report", body: ["ssid": ssid])
        connection.send(packet: packet)
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.connectivity_report",
              let deviceId = connection.peerDeviceInfo?.deviceId else { return }

        if let strengths = packet.object(for: "signalStrengths") {
            var parsed: [Int64: SignalStrength] = [:]
            for (subId, entry) in strengths {
                guard let subId = Int64(subId), let entry = entry as? [String: Any] else { continue }
                parsed[subId] = SignalStrength(
                    networkType: entry["networkType"] as? String ?? "Unknown",
                    strength: entry["signalStrength"] as? Int ?? 0
                )
            }
            // Prefer whichever subscription has the best signal.
            signalStrength[deviceId] = parsed.values.max { $0.strength < $1.strength }
            subscriptions[deviceId] = parsed
        }

        if let rawSsid = packet.string(for: "ssid") {
            if let ssid = sanitizeSsid(rawSsid) {
                wifiSSID[deviceId] = ssid
            } else {
                wifiSSID.removeValue(forKey: deviceId)
            }
        } else {
            // No SSID key in this report: the peer has no WiFi SSID to report right now.
            wifiSSID.removeValue(forKey: deviceId)
        }
    }

    // MARK: - WiFiSSIDMonitorDelegate

    public func ssidDidChange() {
        broadcastSSID()
    }
}
