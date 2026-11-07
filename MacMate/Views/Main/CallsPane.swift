//
//  CallsPane.swift
//  MacMate
//
//  Telephony controls, incoming call alerts, ringer silencing, and media auto-pause.
//  Backed by TelephonyPlugin, CallCard, and CallMediaPauser.
//

import SwiftUI
import AppKit

public struct CallsPane: View {
    let device: DeviceViewModel

    @AppStorage(CallMediaPauser.settingKey) private var pauseMediaDuringCalls = true
    @AppStorage(CallCard.settingKey) private var showFloatingCallCard = true
    @State private var ringerSilenced = false

    public init(device: DeviceViewModel) {
        self.device = device
    }

    private var activeCaller: CallCard.Caller? {
        if CallCard.shared.currentDeviceId == device.id {
            return CallCard.shared.currentCaller
        }
        return nil
    }

    private var activePhase: CallCard.Phase? {
        if CallCard.shared.currentDeviceId == device.id {
            return CallCard.shared.currentPhase
        }
        return nil
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calls")
                            .font(MMFont.hero)
                        Text("Real-time call alerts, ringer silencing, and audio management.")
                            .font(MMFont.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MMStatusPill(
                        title: device.isConnected ? "Telephony Active" : "Disconnected",
                        systemImage: "phone.fill",
                        statusColor: device.isConnected ? MMColor.statusConnected : MMColor.statusNeutral
                    )
                }

                if !device.isConnected {
                    MMSectionGate(
                        state: .noDevice,
                        sectionTitle: "Calls",
                        systemImage: "phone"
                    ) { EmptyView() }
                } else {
                    if let caller = activeCaller, let phase = activePhase {
                        activeCallCard(caller: caller, phase: phase)
                    } else {
                        idleStateCard
                    }

                    telephonyFeaturesCard
                    architectureNoteCard
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Active Call Card

    private func activeCallCard(caller: CallCard.Caller, phase: CallCard.Phase) -> some View {
        MMCard(radius: 18, showsGlow: true, glowColor: MMColor.statusConnected) {
            VStack(spacing: 16) {
                switch phase {
                case .ringing(let silenced):
                    MMStatusPill(
                        title: (silenced || ringerSilenced) ? "Ringer Silenced" : "Incoming Call…",
                        systemImage: "phone.bubble.fill",
                        statusColor: (silenced || ringerSilenced) ? MMColor.statusWarning : MMColor.statusConnected,
                        showPulse: true
                    )
                case .onCall:
                    MMStatusPill(
                        title: "Call in Progress",
                        systemImage: "phone.fill",
                        statusColor: MMColor.electricCyanStart,
                        showPulse: true
                    )
                }

                // Caller Avatar
                if let photo = caller.photo {
                    Image(nsImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                } else {
                    InitialsAvatar(name: caller.name, size: 72)
                }

                VStack(spacing: 4) {
                    Text(caller.name)
                        .font(MMFont.sectionHeader)
                        .lineLimit(1)
                    if let number = caller.number {
                        Text(number)
                            .font(MMFont.telemetry)
                            .foregroundStyle(.secondary)
                    }
                    Text("via \(caller.deviceName)")
                        .font(MMFont.caption)
                        .foregroundStyle(.secondary)
                }

                if case .ringing(let silenced) = phase {
                    HStack(spacing: 20) {
                        Button(action: {
                            TelephonyPlugin.muteRinger(deviceId: device.id)
                            ringerSilenced = true
                        }) {
                            Label(
                                (silenced || ringerSilenced) ? "Ringer Muted" : "Mute Ringer",
                                systemImage: "bell.slash.fill"
                            )
                            .font(MMFont.bodyMedium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MMColor.statusWarning)
                        .disabled(silenced || ringerSilenced)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Idle State Card

    private var idleStateCard: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    MMIconTile(
                        systemImage: "phone.badge.checkmark",
                        size: 40,
                        iconSize: 18,
                        gradient: MMColor.accentPrimaryGradient
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready for Incoming Calls")
                            .font(MMFont.cardTitle)
                        Text("When someone calls \(device.name), MacMate alerts you instantly on your Mac.")
                            .font(MMFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: {
                        TelephonyPlugin.muteRinger(deviceId: device.id)
                    }) {
                        Label("Silence Phone Ringer Now", systemImage: "bell.slash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(18)
        }
    }

    // MARK: - Features Card

    private var telephonyFeaturesCard: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Call Management Preferences")
                    .font(MMFont.cardTitle)

                Toggle(isOn: $pauseMediaDuringCalls) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause Mac audio during calls")
                            .font(MMFont.bodyMedium)
                        Text("Automatically pauses music, podcasts, or videos on this Mac while your phone is ringing or on a call.")
                            .font(MMFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                Toggle(isOn: $showFloatingCallCard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show incoming calls in floating card")
                            .font(MMFont.bodyMedium)
                        Text("Displays a native floating HUD at the top right of your display with caller ID and instant ringer silence control.")
                            .font(MMFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(18)
        }
    }

    // MARK: - Architecture Note Card

    private var architectureNoteCard: some View {
        MMCard(radius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Audio Routing Architecture", systemImage: "info.circle")
                    .font(MMFont.cardTitle)

                Text("MacMate controls call telemetry, contact lookup, incoming alerts, and ringer silencing via the encrypted KDE Connect protocol. Live microphone and speaker audio routing requires connecting your phone to your Mac via Bluetooth.")
                    .font(MMFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }
}

