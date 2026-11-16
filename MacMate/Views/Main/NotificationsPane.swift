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
    private let store: NotificationModeStore

    @State private var filter: NotificationModeFilter = .all
    @State private var showResetAllConfirmation = false

    public init(device: DeviceViewModel, store: NotificationModeStore = .shared) {
        self.device = device
        self.store = store
    }

    public var body: some View {
        let customized = store.customizedApps
        let allGroups = NotificationGroupBuilder.build(notifications: device.notifications, customized: customized)
        let visibleGroups = NotificationGroupBuilder.filter(allGroups, by: filter)

        Group {
            if !device.isConnected {
                MMSectionGate(
                    state: .noDevice,
                    sectionTitle: "Notifications",
                    systemImage: "bell"
                ) { EmptyView() }
            } else if device.notifications.isEmpty && customized.isEmpty {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell.slash",
                    description: Text("Notifications on \(device.name) appear here and in Notification Center. Turn on notification sync in KDE Connect on your phone if they don't.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
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

                            HStack(spacing: 8) {
                                if !customized.isEmpty {
                                    Button("Reset All…", role: .destructive) {
                                        showResetAllConfirmation = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Reset all application notification modes")
                                }

                                let visibleDismissableItems = NotificationGroupBuilder.dismissableItems(in: visibleGroups)
                                if !visibleDismissableItems.isEmpty {
                                    Button(filter == .all ? "Clear All" : "Clear Filtered") {
                                        for notification in visibleDismissableItems {
                                            device.dismiss(notification)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel(filter == .all ? "Clear all notifications" : "Clear filtered notifications")
                                }
                            }
                        }

                        // Mode Filter Bar
                        Picker("Filter", selection: $filter) {
                            ForEach(NotificationModeFilter.allCases) { filterCase in
                                Text(filterCase.title).tag(filterCase)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Filter apps by notification mode")

                        // App groups or filter empty state
                        if visibleGroups.isEmpty {
                            ContentUnavailableView {
                                Label(emptyFilterTitle, systemImage: filter.symbol)
                            } description: {
                                Text(emptyFilterDescription)
                            } actions: {
                                if filter != .all {
                                    Button("Show All") {
                                        filter = .all
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 32)
                        } else {
                            ForEach(visibleGroups) { group in
                                let selectMode: (NotificationMode) -> Void = { newMode in
                                    store.setMode(newMode, for: group.key, displayName: group.displayName)
                                }
                                let resetMode: () -> Void = {
                                    store.resetMode(for: group.key)
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    // Group Header
                                    HStack(alignment: .center, spacing: 10) {
                                        AppIconTileView(packageId: group.packageId, appName: group.displayName)

                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack(spacing: 6) {
                                                Text(group.displayName)
                                                    .font(MMFont.cardTitle)
                                                    .accessibilityAddTraits(.isHeader)
                                                if let disambiguator = group.disambiguator {
                                                    Text(disambiguator)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }

                                        Spacer()

                                        if !group.items.isEmpty {
                                            Text("\(group.items.count)")
                                                .font(MMFont.caption)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(.quaternary))
                                                .foregroundStyle(.secondary)
                                                .accessibilityLabel("\(group.items.count) \(group.items.count == 1 ? "notification" : "notifications")")
                                        }

                                        if group.canConfigure || group.canReset {
                                            AppModeMenu(
                                                mode: group.mode,
                                                appName: group.displayName,
                                                canConfigure: group.canConfigure,
                                                canReset: group.canReset,
                                                onSelect: selectMode,
                                                onReset: resetMode
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .contextMenu {
                                        if group.canConfigure || group.canReset {
                                            AppModeMenuContent(
                                                mode: group.mode,
                                                appName: group.displayName,
                                                canConfigure: group.canConfigure,
                                                canReset: group.canReset,
                                                onSelect: selectMode,
                                                onReset: resetMode
                                            )
                                        }
                                    }

                                    if group.mode == .muted {
                                        HStack(spacing: 6) {
                                            Image(systemName: "info.circle")
                                                .font(.caption)
                                                .accessibilityHidden(true)
                                            Text("Banners hidden. Verification codes still appear.")
                                                .font(.caption)
                                        }
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                    }

                                    // Content card or zero-notification placeholder
                                    if group.items.isEmpty {
                                        HStack {
                                            Text("No active notifications")
                                                .font(MMFont.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text("Applies to new notifications")
                                                .font(MMFont.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(.quaternary.opacity(0.3))
                                        )
                                    } else {
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
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .animation(.default, value: device.notifications)
                .animation(.default, value: filter)
                .animation(.default, value: store.revision)
            }
        }
        .confirmationDialog(
            "Reset All App Notification Modes?",
            isPresented: $showResetAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset \(customized.count) \(customized.count == 1 ? "App" : "Apps")", role: .destructive) {
                store.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every application will return to Normal mode across all paired devices.")
        }
    }

    private var emptyFilterTitle: String {
        switch filter {
        case .all: return "No Notifications"
        case .normal: return "No Normal Notifications"
        case .silent: return "No Silent Apps"
        case .muted: return "No Muted Apps"
        }
    }

    private var emptyFilterDescription: String {
        switch filter {
        case .all:
            return "Notifications on \(device.name) appear here."
        case .normal:
            return "No apps or notifications are currently in Normal mode."
        case .silent:
            return "Apps set to Silent deliver banners without playing notification alert sounds."
        case .muted:
            return "Apps set to Muted suppress native banners while keeping notifications in this list."
        }
    }
}

// MARK: - App Icon Tile View

private struct AppIconTileView: View {
    let packageId: String?
    let appName: String

    var body: some View {
        if let image = AppIconResolver.shared.tileImage(forPackage: packageId, appName: appName) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - App Mode Menu & Content

private struct AppModeMenu: View {
    let mode: NotificationMode
    let appName: String
    var canConfigure: Bool = true
    var canReset: Bool = true
    let onSelect: (NotificationMode) -> Void
    let onReset: () -> Void

    var body: some View {
        Menu {
            AppModeMenuContent(
                mode: mode,
                appName: appName,
                canConfigure: canConfigure,
                canReset: canReset,
                onSelect: onSelect,
                onReset: onReset
            )
        } label: {
            Label(modeTitle, systemImage: modeSymbol)
                .font(.callout)
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Notification mode for \(appName)")
        .accessibilityValue(modeTitle)
    }

    private var modeTitle: String {
        switch mode {
        case .normal: return "Normal"
        case .silent: return "Silent"
        case .muted: return "Muted"
        }
    }

    private var modeSymbol: String {
        switch mode {
        case .normal: return "bell"
        case .silent: return "bell.slash"
        case .muted: return "speaker.slash"
        }
    }
}

private struct AppModeMenuContent: View {
    let mode: NotificationMode
    let appName: String
    var canConfigure: Bool = true
    var canReset: Bool = true
    let onSelect: (NotificationMode) -> Void
    let onReset: () -> Void

    var body: some View {
        if canConfigure {
            Section {
                Button {
                    onSelect(.normal)
                } label: {
                    HStack {
                        Text("Normal (Banner & Sound)")
                        if mode == .normal {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    onSelect(.silent)
                } label: {
                    HStack {
                        Text("Silent (Banner, No Sound)")
                        if mode == .silent {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    onSelect(.muted)
                } label: {
                    HStack {
                        Text("Muted (In-App Only)")
                        if mode == .muted {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        if canReset && mode != .normal {
            if canConfigure {
                Divider()
            }
            Button("Reset to Normal", action: onReset)
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

    nonisolated func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    nonisolated func setImage(_ image: NSImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    nonisolated func removeAll() {
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
