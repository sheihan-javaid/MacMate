//
//  SMSPluginTests.swift
//  MacMateTests
//

import Testing
import Foundation
@testable import MacMate

@MainActor
struct SMSPluginTests {
    private func connection(_ deviceId: String) -> DeviceConnection {
        let conn = DeviceConnection(host: "127.0.0.1", port: 1234, targetDeviceId: nil, isOutgoing: false)
        conn.setPeerDeviceInfoForTesting(DeviceInfo(
            deviceId: deviceId, deviceName: deviceId, deviceType: .phone,
            incomingCapabilities: [], outgoingCapabilities: []))
        return conn
    }

    private func messages(threadId: Int, body: String) -> NetworkPacket {
        NetworkPacket(type: SMSPlugin.messagesType, body: [
            "messages": [[
                "body": body, "thread_id": threadId, "type": 1, "event": 1,
                "date": 1_700_000_000_000, "addresses": [["address": "+100"]]
            ] as [String: Any]]
        ])
    }

    /// The plugin applies packets on the main queue; wait for what it queued.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Thread ids are only unique on one phone, so two phones that both have a
    /// thread 1 must not end up sharing it.
    @Test func sameThreadIdOnTwoPhonesStaysSeparate() async {
        let plugin = SMSPlugin()
        plugin.handlePacket(connection: connection("phone-a"), packet: messages(threadId: 1, body: "from A"))
        plugin.handlePacket(connection: connection("phone-b"), packet: messages(threadId: 1, body: "from B"))
        await settle()

        #expect(plugin.conversations["phone-a"]?[1]?.messages.map(\.body) == ["from A"])
        #expect(plugin.conversations["phone-b"]?[1]?.messages.map(\.body) == ["from B"])
    }
}
