//
//  MacMateAppModelTests.swift
//  MacMateTests
//

import Foundation
import Testing
@testable import MacMate

@MainActor
struct MacMateAppModelTests {

    private func makeModel() -> MacMateAppModel {
        MacMateAppModel(isMock: true)
    }

    // MARK: - Stale SSID cleared on status change

    @Test func wifiSSIDClearedWhenDeviceGoesOffline() {
        let model = makeModel()
        let deviceId = "dev-offline"

        // Pre-populate cache with a connected device that has a stale SSID.
        let connected = DeviceViewModel(
            id: deviceId, name: "Phone", deviceType: .phone, status: .connected,
            wifiSSID: "OldNetwork"
        )
        model.deviceCache[deviceId] = connected

        // Transition to offline.
        let offline = model.device(id: deviceId, name: "Phone", type: .phone, status: .offline)

        #expect(offline.wifiSSID == nil, "Stale SSID should be cleared when device goes offline")
        #expect(offline.status == .offline)
    }

    @Test func wifiSSIDClearedWhenDeviceReconnects() {
        let model = makeModel()
        let deviceId = "dev-reconnect"

        // Pre-populate cache with an offline device that has a stale SSID.
        let offline = DeviceViewModel(
            id: deviceId, name: "Phone", deviceType: .phone, status: .offline,
            wifiSSID: "OldNetwork"
        )
        model.deviceCache[deviceId] = offline

        // Transition to connected (reconnect).
        let reconnected = model.device(id: deviceId, name: "Phone", type: .phone, status: .connected)

        #expect(reconnected.wifiSSID == nil, "Stale SSID should be cleared when device reconnects")
        #expect(reconnected.status == .connected)
    }

    @Test func wifiSSIDRetainedForConnectedDeviceWithoutStatusChange() {
        let model = makeModel()
        let deviceId = "dev-persist"

        // A connected device whose status doesn't change keeps its SSID.
        let existing = DeviceViewModel(
            id: deviceId, name: "Phone", deviceType: .phone, status: .connected,
            wifiSSID: "PersistentNetwork"
        )
        model.deviceCache[deviceId] = existing

        let unchanged = model.device(id: deviceId, name: "Phone", type: .phone, status: .connected)

        #expect(unchanged.wifiSSID == "PersistentNetwork",
                "SSID should be retained when status does not change")
    }
}
