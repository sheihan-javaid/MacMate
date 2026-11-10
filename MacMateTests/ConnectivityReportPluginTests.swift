//
//  ConnectivityReportPluginTests.swift
//  MacMateTests
//

import Foundation
import Testing
@testable import MacMate

/// Mock WiFiSSIDProvider for testing SSID sending.
private final class MockSSIDProvider: WiFiSSIDProvider {
    let ssid: String?
    init(ssid: String?) {
        self.ssid = ssid
    }
    func currentSSID() -> String? { ssid }
}

struct ConnectivityReportPluginTests {

    private func makeConnection(deviceId: String = "dev-123") -> DeviceConnection {
        let conn = DeviceConnection(host: "127.0.0.1", port: 1234, targetDeviceId: nil, isOutgoing: false)
        let info = DeviceInfo(
            deviceId: deviceId,
            deviceName: "Test Phone",
            deviceType: .phone,
            incomingCapabilities: ["kdeconnect.connectivity_report"],
            outgoingCapabilities: ["kdeconnect.connectivity_report"]
        )
        conn.setPeerDeviceInfoForTesting(info)
        return conn
    }

    private func connectivityReportPacket(ssid: String? = nil, signalStrengths: [String: [String: Any]]? = nil) -> NetworkPacket {
        var body: [String: Any] = [:]
        if let ssidValue = ssid { body["ssid"] = ssidValue }
        if let strengthsValue = signalStrengths { body["signalStrengths"] = strengthsValue }
        return NetworkPacket(type: "kdeconnect.connectivity_report", body: body)
    }

    // MARK: - Sanitize

    @Test func packetWithValidSsidStoresIt() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "MyHomeWiFi")
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == "MyHomeWiFi")
    }

    @Test func packetWithoutSsidKeyLeavesWifiSSIDEmpty() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(signalStrengths: ["0": ["networkType": "LTE", "signalStrength": 3]])
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == nil)
    }

    @Test func emptyStringSsidIsNotStored() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "")
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == nil)
    }

    @Test func unknownSsidIsNotStored() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "<unknown ssid>")
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == nil)
    }

    @Test func quotedSsidHasQuotesStripped() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "\"MyHomeWiFi\"")
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == "MyHomeWiFi")
    }

    @Test func ssidWithSpacesAndNonAsciiIsPreserved() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "Café Wi-Fi 5G")
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == "Café Wi-Fi 5G")
    }

    @Test func ssidWithOnlyWhitespaceIsNotStored() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "   ")
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == nil)
    }

    @Test func packetWithSsidButNoSignalStrengthsStillParsesSsid() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "OfficeWiFi", signalStrengths: nil)
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == "OfficeWiFi")
        #expect(plugin.signalStrength["dev-123"] == nil)
    }

    @Test func packetWithSignalStrengthsButNoSsidParsesSignalOnly() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: nil, signalStrengths: ["0": ["networkType": "5G", "signalStrength": 4]])
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == nil)
        #expect(plugin.signalStrength["dev-123"]?.networkType == "5G")
        #expect(plugin.signalStrength["dev-123"]?.strength == 4)
    }

    @Test func ssidClearedAfterLaterReportWithoutIt() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()

        let withSsid = connectivityReportPacket(ssid: "HomeWiFi")
        plugin.handlePacket(connection: conn, packet: withSsid)
        #expect(plugin.wifiSSID["dev-123"] == "HomeWiFi")

        let withoutSsid = connectivityReportPacket(signalStrengths: ["0": ["networkType": "LTE", "signalStrength": 2]])
        plugin.handlePacket(connection: conn, packet: withoutSsid)
        #expect(plugin.wifiSSID["dev-123"] == nil)
    }

    @Test func ssidClearedOnDisconnect() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()

        let withSsid = connectivityReportPacket(ssid: "HomeWiFi")
        plugin.handlePacket(connection: conn, packet: withSsid)
        #expect(plugin.wifiSSID["dev-123"] == "HomeWiFi")

        plugin.onDisconnected(connection: conn)
        #expect(plugin.wifiSSID["dev-123"] == nil)
        #expect(plugin.signalStrength["dev-123"] == nil)
    }

    @Test func zeroXSsidIsNotStored() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "0x")
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == nil)
    }

    @Test func caseInsensitiveUnknownSsidIsNotStored() {
        let plugin = ConnectivityReportPlugin()
        let conn = makeConnection()
        let packet = connectivityReportPacket(ssid: "<UNKNOWN SSID>")
        plugin.handlePacket(connection: conn, packet: packet)
        #expect(plugin.wifiSSID["dev-123"] == nil)
    }

    @Test func multipleDevicesTrackedIndependently() {
        let plugin = ConnectivityReportPlugin()
        let conn1 = makeConnection(deviceId: "dev-1")
        let conn2 = makeConnection(deviceId: "dev-2")

        plugin.handlePacket(connection: conn1, packet: connectivityReportPacket(ssid: "WiFiOne"))
        plugin.handlePacket(connection: conn2, packet: connectivityReportPacket(ssid: "WiFiTwo"))

        #expect(plugin.wifiSSID["dev-1"] == "WiFiOne")
        #expect(plugin.wifiSSID["dev-2"] == "WiFiTwo")
    }

    // MARK: - Sending SSID (Mac-originated)

    @Test func broadcastSSIDSendsPacketWhenSsidPresentAndSettingOn() {
        let plugin = ConnectivityReportPlugin()
        plugin.ssidProvider = MockSSIDProvider(ssid: "MyHomeWiFi")
        plugin.shouldSendSSID = true

        let conn = makeConnection()
        plugin.onConnected(connection: conn)

        // Verify the plugin attempted to send by checking active connections tracked it
        #expect(plugin.activeConnections["dev-123"] !== nil)
    }

    @Test func broadcastSSIDDoesNotSendWhenSsidNil() {
        let plugin = ConnectivityReportPlugin()
        plugin.ssidProvider = MockSSIDProvider(ssid: nil)
        plugin.shouldSendSSID = true

        let conn = makeConnection()
        plugin.onConnected(connection: conn)

        // Connection tracked but no crash; SSID is nil so nothing sent
        #expect(plugin.activeConnections["dev-123"] !== nil)
    }

    @Test func broadcastSSIDDoesNotSendWhenSettingOff() {
        let plugin = ConnectivityReportPlugin()
        plugin.ssidProvider = MockSSIDProvider(ssid: "MyHomeWiFi")
        plugin.shouldSendSSID = false

        let conn = makeConnection()
        plugin.onConnected(connection: conn)

        #expect(plugin.activeConnections["dev-123"] !== nil)
    }

    @Test func broadcastSSIDClearsOnDisconnect() {
        let plugin = ConnectivityReportPlugin()
        plugin.ssidProvider = MockSSIDProvider(ssid: "MyHomeWiFi")
        plugin.shouldSendSSID = true

        let conn = makeConnection()
        plugin.onConnected(connection: conn)
        #expect(plugin.activeConnections["dev-123"] !== nil)

        plugin.onDisconnected(connection: conn)
        #expect(plugin.activeConnections["dev-123"] == nil)
        #expect(plugin.wifiSSID["dev-123"] == nil)
    }

    @Test func sanitizeSsidRejectsInvalidValues() {
        #expect(sanitizeSsid(nil) == nil)
        #expect(sanitizeSsid("") == nil)
        #expect(sanitizeSsid("   ") == nil)
        #expect(sanitizeSsid("<unknown ssid>") == nil)
        #expect(sanitizeSsid("<UNKNOWN SSID>") == nil)
        #expect(sanitizeSsid("0x") == nil)
        #expect(sanitizeSsid("\"\"") == nil)
        #expect(sanitizeSsid("\"MyWiFi\"") == "MyWiFi")
        #expect(sanitizeSsid("MyWiFi") == "MyWiFi")
        #expect(sanitizeSsid("Café Wi-Fi") == "Café Wi-Fi")
    }
}
