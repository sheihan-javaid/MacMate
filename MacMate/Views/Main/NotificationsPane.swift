//
//  NotificationsPane.swift
//  MacMate
//
//  Notifications grouped by app with inline dismissal and replies.
//  Includes F-04: Bounded image cache and asynchronous off-main-thread image decoding.
//

import SwiftUI
import AppKit

public struct NotificationsPane: View {
    let device: DeviceViewModel

    public init(device: DeviceViewModel) {
        self.device = device
    }

    /// Notifications grouped by app, the app with the newest one first.
    private var groups: [(app: String, items: [PhoneNotification])] {
        let byApp = Dictionary(grouping: device.notifications, by: \.appName)
        return byApp
            .map { (app: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { ($0.items.first?.date ?? .distantPast) > ($1.items.first?.date ?? .distantPast) }
    }

    public var body: some View {
        Group {
            if !device.isConnected {
                MMSectionGate(
                    state: .noDevice,
                    sectionTitle: "Notifications",
                    systemImage: "bell"
                ) { EmptyView() }
            } else if device.notifications.isEmpty {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell.slash",
                    description: Text("Notifications on \(device.name) appear here and in Notification Center. Turn on notification sync in KDE Connect on your phone if they don't.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // Header
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notifications")
                                    .font(MMFont.hero)
                                Text("\(device.notifications.count) notifications on \(device.name)")
                                    .font(MMFont.body)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.notifications.contains(where: \.isDismissable) {
                                Button("Clear All") {
                                    for notification in device.notifications where notification.isDismissable {
                                        device.dismiss(notification)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        // App groups
                        ForEach(groups, id: \.app) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(group.app)
                                        .font(MMFont.cardTitle)
                                    Spacer()
                                    Text("\(group.items.count)")
                                        .font(MMFont.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(.quaternary))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 4)

                                MMCard(radius: 14) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, notification in
                                            if index > 0 { Divider().padding(.leading, 16) }
                                            NotificationRow(notification: notification, device: device)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .animation(.default, value: device.notifications)
            }
        }
    }
}

// MARK: - Notification Image Cache (F-04)

final class NotificationImageCache: @unchecked Sendable {
    static let shared = NotificationImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1024 * 1024 // 16 MB bounded cache
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: NSImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

// MARK: - Notification Image Decoder (F-04)

enum NotificationImageDecoder {
    /// Decodes image data completely off the main thread with cooperative cancellation propagation.
    /// Connects parent task cancellation to the detached decoding task, and verifies cancellation
    /// before decoding and before caching to avoid wasting CPU/memory or polluting the cache.
    nonisolated static func decode(data: Data, key: String) async -> NSImage? {
        guard !Task.isCancelled else { return nil }

        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            guard let image = NSImage(data: data) else { return nil }
            guard !Task.isCancelled else { return nil }

            let width = Int(image.size.width)
            let height = Int(image.size.height)
            let cost = max(1, width * height * 4)

            // Cache only if not cancelled
            if !Task.isCancelled {
                NotificationImageCache.shared.setImage(image, forKey: key, cost: cost)
            }
            return image
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

// MARK: - Notification Image View (F-04)

private struct NotificationImageView: View {
    let notification: PhoneNotification
    @State private var decodedImage: NSImage?

    var body: some View {
        Group {
            if let image = decodedImage {
                if notification.imageIsGlyph {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("\(notification.appName) icon")
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel("Image from \(notification.appName)")
                }
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
        }
        .task(id: notification.id) {
            guard let data = notification.imageData, !data.isEmpty else {
                decodedImage = nil
                return
            }

            let key = "\(notification.id)_\(data.count)"
            if let cached = NotificationImageCache.shared.image(forKey: key) {
                decodedImage = cached
                return
            }

            // F-04: Asynchronous off-main-thread image decode with cooperative cancellation
            let expectedId = notification.id
            let decoded = await NotificationImageDecoder.decode(data: data, key: key)

            if !Task.isCancelled && notification.id == expectedId {
                decodedImage = decoded
            }
        }
    }
}

// MARK: - Notification Row

private struct NotificationRow: View {
    let notification: PhoneNotification
    let device: DeviceViewModel

    @State private var isReplying = false
    @State private var reply = ""
    @FocusState private var isReplyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                NotificationImageView(notification: notification)

                Text(notification.title.isEmpty ? notification.appName : notification.title)
                    .font(MMFont.bodyMedium)
                    .lineLimit(1)

                Spacer()

                Text(notification.date, format: .relative(presentation: .named))
                    .font(MMFont.telemetrySmall)
                    .foregroundStyle(.secondary)
            }

            if !notification.text.isEmpty {
                Text(notification.text)
                    .font(MMFont.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)
            }

            if isReplying {
                HStack(spacing: 8) {
                    TextField("Reply to \(notification.title.isEmpty ? notification.appName : notification.title)", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .focused($isReplyFocused)
                        .onSubmit(sendReply)
                    Button("Cancel") { isReplying = false }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                    Button("Send", action: sendReply)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(MMColor.electricCyanEnd)
                        .controlSize(.small)
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 42)
                .padding(.top, 4)
            }

            // Actions
            HStack(spacing: 8) {
                if let code = notification.code {
                    CopyCodeButton(code: code)
                }

                if notification.replyId != nil && !isReplying {
                    Button(action: {
                        isReplying = true
                        isReplyFocused = true
                    }) {
                        Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                if notification.isDismissable {
                    Button(action: { device.dismiss(notification) }) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss notification")
                }
            }
            .padding(.leading, 42)
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sendReply() {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        device.reply(to: notification, text: trimmed)
        reply = ""
        isReplying = false
    }
}
