//
//  SMSPlugin.swift
//  MacMate
//
//  Plugin for viewing and replying to SMS conversations from macOS.
//

import Foundation
import Combine

public final class SMSPlugin: ObservableObject, MacMatePlugin, @unchecked Sendable {
    public static let messagesType = "kdeconnect.sms.messages"
    public static let attachmentFileType = "kdeconnect.sms.attachment_file"
    public static let requestType = "kdeconnect.sms.request"
    public static let requestConversationsType = "kdeconnect.sms.request_conversations"
    public static let requestConversationType = "kdeconnect.sms.request_conversation"
    public static let requestAttachmentType = "kdeconnect.sms.request_attachment"

    public var supportedPacketTypes: [String] {
        [Self.messagesType, Self.attachmentFileType]
    }

    /// Threads per device, then by thread id: thread ids are only unique on one phone.
    @Published public private(set) var conversations: [String: [Int64: SMSConversation]] = [:]
    @Published public private(set) var activeThreadId: Int64?

    private let lock = NSLock()

    public init() {}

    public func onConnected(connection: DeviceConnection) {
        requestAllConversations(connection: connection)
    }

    public func onDisconnected(connection: DeviceConnection) {}

    public func handlePacket(connection: DeviceConnection, packet: NetworkPacket) {
        if packet.type == Self.messagesType {
            guard let deviceId = connection.peerDeviceInfo?.deviceId else { return }
            handleBatchMessages(packet: packet, deviceId: deviceId)
        }
    }

    public func handlePayload(connection: DeviceConnection, packet: NetworkPacket, fileURL payloadURL: URL) {
        guard packet.type == Self.attachmentFileType else { return }
        // `filename` is the attachment's identifier on the phone; it is matched
        // as-is below but must never be used as a path without sanitising.
        let filename = packet.string(for: "filename") ?? "attachment"
        let deviceId = connection.peerDeviceInfo?.deviceId
        let attachmentDir = AppIdentity.cacheFolder(.attachments)

        try? FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
        let fileURL = attachmentDir.appendingPathComponent(SafeFilename.sanitize(filename, fallback: "attachment"))

        do {
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: payloadURL, to: fileURL)
            MacMateLog("[SMSPlugin] Saved SMS attachment to \(fileURL.path)")

            let targetThreadId = (packet.int64(for: "thread_id")) != 0 ? packet.int64(for: "thread_id") : nil
            if let threadId = targetThreadId, let deviceId {
                DispatchQueue.main.async {
                    if var conversation = self.conversations[deviceId]?[threadId] {
                        for msgIndex in conversation.messages.indices {
                            for attIndex in conversation.messages[msgIndex].attachments.indices {
                                if conversation.messages[msgIndex].attachments[attIndex].uniqueIdentifier == filename {
                                    conversation.messages[msgIndex].attachments[attIndex].localURL = fileURL
                                }
                            }
                        }
                        self.conversations[deviceId]?[threadId] = conversation
                    }
                }
            }
        } catch {
            MacMateLog("[SMSPlugin] Failed to write attachment: \(error)")
        }
    }

    // MARK: - Actions

    public func requestAllConversations(connection: DeviceConnection) {
        let packet = NetworkPacket(type: Self.requestConversationsType)
        connection.send(packet: packet)
        MacMateLog("[SMSPlugin] Requested all SMS conversations")
    }

    /// Asks for a thread's messages. A negative `rangeStartTimestamp` means
    /// the newest ones; otherwise the phone returns messages older than it
    /// (milliseconds since 1970). 0 asked for messages from before 1970, which
    /// is why only each thread's latest message ever showed.
    public func requestConversation(threadId: Int64, rangeStartTimestamp: Int64 = -1, numberToRequest: Int = 50, connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: Self.requestConversationType,
            body: [
                "threadID": AnyCodable(threadId),
                "rangeStartTimestamp": AnyCodable(rangeStartTimestamp),
                "numberToRequest": AnyCodable(numberToRequest)
            ]
        )
        connection.send(packet: packet)
        MacMateLog("[SMSPlugin] Requested conversation \(threadId)")
    }

    /// The page before the oldest message loaded, growing like desktop KDE
    /// Connect's: as many as are already loaded, at least 50.
    /// Call on the main thread, where `conversations` is read and written.
    public func requestEarlierMessages(threadId: Int64, connection: DeviceConnection) {
        let deviceId = connection.peerDeviceInfo?.deviceId ?? ""
        let loaded = conversations[deviceId]?[threadId]?.messages ?? []
        guard let oldest = loaded.first?.date else {
            requestConversation(threadId: threadId, connection: connection)
            return
        }
        requestConversation(
            threadId: threadId,
            rangeStartTimestamp: Int64(oldest.timeIntervalSince1970 * 1000),
            numberToRequest: max(50, loaded.count),
            connection: connection
        )
    }

    public func requestAttachment(partId: Int64, uniqueIdentifier: String, connection: DeviceConnection) {
        let packet = NetworkPacket(
            type: Self.requestAttachmentType,
            body: [
                "part_id": AnyCodable(partId),
                "unique_identifier": AnyCodable(uniqueIdentifier)
            ]
        )
        connection.send(packet: packet)
    }

    /// Sends from SIM `subId` when given, else the one the conversation uses.
    public func sendSMS(text: String, to addresses: [String], threadId: Int64? = nil, subId: Int64? = nil, connection: DeviceConnection) {
        guard !text.isEmpty, !addresses.isEmpty else { return }

        let addressList = addresses.map { ["address": AnyCodable($0)] }
        var body: [String: AnyCodable] = [
            "version": AnyCodable(2),
            "addresses": AnyCodable(addressList),
            "messageBody": AnyCodable(text)
        ]
        // Reply from the SIM the conversation uses, as desktop KDE Connect
        // does. Without it the phone sends from its default SMS SIM, and a
        // dual-SIM phone set to "Ask every time" has none, so nothing is sent.
        // Only a SIM the phone reports now counts, and only when it has more
        // than one: old messages can name a SIM that has since been replaced,
        // and the phone silently drops a message for a SIM it doesn't have.
        let activeSIMs = connection.peerDeviceInfo
            .flatMap { MacMateService.shared.connectivityReportPlugin.subscriptions[$0.deviceId] }
            .map { Set($0.keys) } ?? []
        let sendingDeviceId = connection.peerDeviceInfo?.deviceId ?? ""
        let conversationSubId = threadId.flatMap { conversations[sendingDeviceId]?[$0]?.messages.last(where: { $0.subId != nil })?.subId }
        let chosenSubId = (subId ?? conversationSubId).flatMap { activeSIMs.count > 1 && activeSIMs.contains($0) ? $0 : nil }
        if let chosenSubId {
            body["subID"] = AnyCodable(chosenSubId)
        }
        let packet = NetworkPacket(type: Self.requestType, body: body)
        connection.send(packet: packet)
        MacMateLog("[SMSPlugin] Dispatched SMS to \(addresses.count) recipient(s), SIM \(chosenSubId.map(String.init) ?? "default")"
            + " (asked for \((subId ?? conversationSubId).map(String.init) ?? "none"), phone has \(activeSIMs.sorted()))")

        // Optimistically add to local messages
        if let targetThreadId = threadId {
            let optimisticMessage = SMSMessage(
                id: UUID(),
                event: 1,
                body: text,
                addresses: addresses,
                date: Date(),
                type: 2, // outgoing
                threadId: targetThreadId,
                read: true
            )
            DispatchQueue.main.async {
                if var conv = self.conversations[sendingDeviceId]?[targetThreadId] {
                    conv.messages.append(optimisticMessage)
                    self.conversations[sendingDeviceId]?[targetThreadId] = conv
                }
            }
        }
    }

    public func setActiveThread(_ threadId: Int64?) {
        DispatchQueue.main.async {
            self.activeThreadId = threadId
        }
    }

    // MARK: - Internal Message Parsing

    private func handleBatchMessages(packet: NetworkPacket, deviceId: String) {
        let rawMessages = packet.objectArray(for: "messages")
        guard !rawMessages.isEmpty else { return }

        var parsedMessages: [SMSMessage] = []
        for raw in rawMessages {
            if let msg = SMSMessage.from(dictionary: raw) {
                parsedMessages.append(msg)
            }
        }

        guard !parsedMessages.isEmpty else { return }

        DispatchQueue.main.async {
            for message in parsedMessages {
                let threadId = message.threadId
                var conversation = self.conversations[deviceId]?[threadId] ?? SMSConversation(threadId: threadId, addresses: message.addresses)

                if conversation.addresses.isEmpty && !message.addresses.isEmpty {
                    conversation.addresses = message.addresses
                }

                // Check for duplicates
                if !conversation.messages.contains(where: {
                    $0.body == message.body &&
                    abs($0.date.timeIntervalSince(message.date)) < 2.0 &&
                    $0.type == message.type
                }) {
                    conversation.messages.append(message)
                }

                // Sort chronologically
                conversation.messages.sort(by: { $0.date < $1.date })
                self.conversations[deviceId, default: [:]][threadId] = conversation
            }
            MacMateLog("[SMSPlugin] Processed \(parsedMessages.count) messages across \(self.conversations[deviceId]?.count ?? 0) threads")
        }
    }
}
