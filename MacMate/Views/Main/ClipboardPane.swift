//
//  ClipboardPane.swift
//  MacMate
//
//  Bidirectional clipboard synchronization management, preview, manual send,
//  and privacy controls backed by ClipboardPlugin and TrustStore.
//

import SwiftUI
import AppKit

public struct ClipboardPane: View {
    let device: DeviceViewModel

    @State private var localClipboardContent: String = ""
    @State private var isCopiedFeedback = false
    @State private var isSentFeedback = false

    public init(device: DeviceViewModel) {
        self.device = device
    }

    private var isSyncEnabled: Bool {
        TrustStore.shared.pairedDevice(for: device.id)?.isClipboardSyncEnabled ?? true
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clipboard")
                            .font(MMFont.hero)
                        Text("Seamless two-way clipboard synchronization between Mac and Android.")
                            .font(MMFont.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MMStatusPill(
                        title: isSyncEnabled && device.isConnected ? "Sync Active" : "Sync Paused",
                        systemImage: "doc.on.clipboard",
                        statusColor: (isSyncEnabled && device.isConnected) ? MMColor.statusConnected : MMColor.statusNeutral
                    )
                }

                if !device.isConnected {
                    MMSectionGate(
                        state: .noDevice,
                        sectionTitle: "Clipboard",
                        systemImage: "doc.on.clipboard"
                    ) { EmptyView() }
                } else {
                    currentPasteboardCard
                    syncSettingsCard
                    privacyCard
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            refreshLocalClipboard()
        }
    }

    // MARK: - Current Pasteboard Card

    private var currentPasteboardCard: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Mac Pasteboard Preview")
                        .font(MMFont.cardTitle)
                    Spacer()
                    Button(action: refreshLocalClipboard) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh clipboard preview")
                }

                if localClipboardContent.isEmpty {
                    Text("Clipboard is currently empty or contains non-text data.")
                        .font(MMFont.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Text(localClipboardContent)
                        .font(MMFont.telemetry)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                        .lineLimit(5)
                }

                HStack(spacing: 12) {
                    Button(action: sendToPhone) {
                        Label(
                            isSentFeedback ? "Sent to \(device.name)!" : "Send to \(device.name)",
                            systemImage: isSentFeedback ? "checkmark" : "paperplane.fill"
                        )
                        .font(MMFont.bodyMedium)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MMColor.electricCyanEnd)
                    .disabled(localClipboardContent.isEmpty)

                    Button("Clear Mac Clipboard") {
                        NSPasteboard.general.clearContents()
                        refreshLocalClipboard()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(18)
        }
    }

    // MARK: - Sync Settings Card

    private var syncSettingsCard: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Synchronization Preferences")
                    .font(MMFont.cardTitle)

                Toggle(
                    isOn: Binding(
                        get: { isSyncEnabled },
                        set: { enabled in
                            TrustStore.shared.setClipboardSyncEnabled(device.id, isEnabled: enabled)
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic two-way clipboard sync")
                            .font(MMFont.bodyMedium)
                        Text("When enabled, copying text on this Mac instantly updates your phone's clipboard, and copying on your phone updates your Mac.")
                            .font(MMFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(MMColor.electricCyanEnd)
                    Text("Echo suppression & loop protection active.")
                        .font(MMFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
    }

    // MARK: - Privacy Card

    private var privacyCard: some View {
        MMCard(radius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Privacy & Battery Protection", systemImage: "shield.lefthalf.filled")
                    .font(MMFont.cardTitle)

                Text("Clipboard polling automatically halts when no sync-enabled device is connected. Passwords copied from standard password managers with transient pasteboard flags are not mirrored.")
                    .font(MMFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func refreshLocalClipboard() {
        localClipboardContent = NSPasteboard.general.string(forType: .string) ?? ""
    }

    private func sendToPhone() {
        device.sendClipboard()
        isSentFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isSentFeedback = false
        }
    }
}

