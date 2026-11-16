//
//  TelephonyPlugin.swift
//  MacMate
//

import AppKit
import UserNotifications

/// Incoming call and messaging events from the phone.
///
/// The peer sends `kdeconnect.telephony` with `event` set to `ringing`,
/// `missedCall`, `talking` or `sms`, plus `phoneNumber`, and `contactName` and
/// a JPEG `phoneThumbnail` when the phone knows the caller. `isCancel` marks a
/// previously announced event as no longer relevant.
public final class TelephonyPlugin: MacMatePlugin, @unchecked Sendable {
    static let requestMuteType = "kdeconnect.telephony.request_mute"
    static let callCategory = "MACMATE_CALL_CATEGORY"
    static let muteAction = "MACMATE_MUTE_RINGER_ACTION"

    public let supportedPacketTypes = ["kdeconnect.telephony"]

    public init() {}

    public func onConnected(connection: DeviceConnection) {}
    public func onDisconnected(connection: DeviceConnection) {
        let deviceId = connection.peerDeviceInfo?.deviceId ?? connection.targetDeviceId ?? ""
        Task { @MainActor in
            CallMediaPauser.shared.callEnded(deviceId)
            CallCard.shared.ended(deviceId: deviceId)
        }
    }

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        guard packet.type == "kdeconnect.telephony",
              let deviceId = connection.peerDeviceInfo?.deviceId ?? connection.targetDeviceId else { return }

        let event = packet.string(for: "event") ?? ""
        let identifier = "macmate-telephony-\(deviceId)-\(event)"
        let isCancel = packet.bool(for: "isCancel")
        let isEndEvent = event == "idle" || event == "callEnded" || event == "ended" || event == "cancel" || event == "cancelled" || event == "hangup"
        let isCall = event == "ringing" || event == "talking"
        MacMateLog("[TelephonyPlugin] \(event)\(isCancel ? " cancelled" : "") from \(connection.peerDeviceInfo?.deviceName ?? deviceId)")

        // A cancel or call termination event retracts what was posted for this call; it ended.
        if isCancel || isEndEvent {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
                "macmate-telephony-\(deviceId)-ringing",
                "macmate-telephony-\(deviceId)-talking",
                identifier
            ])
            Task { @MainActor in
                CallMediaPauser.shared.callEnded(deviceId)
                CallCard.shared.ended(deviceId: deviceId)
            }
            return
        }
        if isCall {
            Task { @MainActor in CallMediaPauser.shared.callStarted(deviceId) }
        }

        // The phone's own contact name wins; otherwise MacMate's copy of the
        // contacts; otherwise the number.
        let number = packet.string(for: "phoneNumber")
        let contact = number.flatMap { MacMateService.shared.contactsPlugin.contactNow(for: $0, on: deviceId) }
        let name = packet.string(for: "contactName").flatMap { $0.isEmpty ? nil : $0 } ?? contact?.name
        let who = name ?? number ?? "Unknown number"
        let photo = packet.string(for: "phoneThumbnail").flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            ?? contact?.photo

        // Calls go to the floating card instead of a banner; a missed call
        // closes it and is posted as usual.
        if CallCard.isEnabled, event == "ringing" || event == "talking" || event == "missedCall" {
            let caller = CallCard.Caller(
                name: who, isContact: name != nil, number: name != nil ? number : nil,
                photo: photo.flatMap(NSImage.init(data:)),
                deviceName: connection.peerDeviceInfo?.deviceName ?? "your phone"
            )
            Task { @MainActor in
                switch event {
                case "ringing":
                    CallCard.shared.ringing(deviceId: deviceId, caller: caller)
                case "talking":
                    CallCard.shared.talking(deviceId: deviceId, caller: caller)
                default:
                    CallMediaPauser.shared.callEnded(deviceId)
                    CallCard.shared.missed(deviceId: deviceId)
                }
            }
            if event != "missedCall" { return }
        }

        let content = UNMutableNotificationContent()
        switch event {
        case "ringing":
            content.title = who
            content.subtitle = "Incoming call"
            if name != nil, let number { content.body = number }
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.categoryIdentifier = Self.callCategory
            content.userInfo = ["deviceId": deviceId]
        case "missedCall":
            content.title = who
            content.subtitle = "Missed call"
            if name != nil, let number { content.body = number }
            content.sound = .default
        case "talking":
            content.title = who
            content.subtitle = "Call in progress"
        case "sms":
            content.title = "Message from \(who)"
            content.body = packet.string(for: "messageBody") ?? ""
        default:
            MacMateLog("[TelephonyPlugin] Ignoring unknown telephony event '\(event)'")
            return
        }
        if let photo, let attachment = Self.attachment(photo) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                MacMateLog("[TelephonyPlugin] Failed to post notification: \(error)")
            }
        }
    }

    /// Asks the phone to silence its ringer, from the incoming-call notification.
    static func muteRinger(deviceId: String) {
        guard let connection = MacMateService.shared.connection(for: deviceId) else { return }
        connection.send(packet: NetworkPacket(type: requestMuteType))
        MacMateLog("[TelephonyPlugin] Asked the phone to mute its ringer")
    }

    /// The caller's photo as a notification attachment. The notification
    /// center moves the file into its own store.
    private static func attachment(_ photo: Data) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macmate-caller-\(UUID().uuidString).jpg")
        guard (try? photo.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "photo", url: url, options: nil)
    }
}
