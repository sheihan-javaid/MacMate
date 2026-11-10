//
//  OverviewPane.swift
//  MacMate
//
//  Connected device overview dashboard: live telemetry, quick actions,
//  Now Playing media controller, recent notifications, and transfer activity.
//

import SwiftUI

public struct OverviewPane: View {
    @Bindable var device: DeviceViewModel
    let onSelectSection: (MacMateSection) -> Void

    public init(device: DeviceViewModel, onSelectSection: @escaping (MacMateSection) -> Void) {
        self.device = device
        self.onSelectSection = onSelectSection
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerCard

                if device.hasNowPlaying {
                    NowPlayingPanel(device: device)
                }

                if !device.notifications.isEmpty {
                    recentNotificationsSection
                }

                recentFilesSection

                RemoteInputRow()
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Header & Quick Actions

    private var headerCard: some View {
        MMCard(radius: 20, showsGlow: device.isConnected, glowColor: MMColor.statusConnected) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(MMColor.accentPrimaryGradient)
                            .frame(width: 58, height: 58)
                            .shadow(color: MMColor.electricCyanStart.opacity(0.3), radius: 8, x: 0, y: 3)

                        Image(systemName: device.deviceType.systemImageName)
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.name)
                            .font(MMFont.hero)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            MMStatusPill(
                                title: device.isViaTailscale ? "Tailscale Mesh" : "Local Wi-Fi",
                                systemImage: device.isViaTailscale ? "point.3.connected.trianglepath.dotted" : "wifi",
                                statusColor: MMColor.statusConnected,
                                showPulse: device.isConnected
                            )

                            if let battery = device.batteryPercent {
                                MMStatusPill(
                                    title: "\(battery)%",
                                    systemImage: DeviceSymbols.battery(battery, charging: device.isCharging),
                                    statusColor: battery <= 15 && !device.isCharging ? MMColor.statusError : (device.isCharging ? MMColor.statusConnected : .secondary)
                                )
                            }

                            if let network = device.networkType, !network.isEmpty {
                                MMStatusPill(
                                    title: network,
                                    systemImage: "cellularbars",
                                    statusColor: .secondary
                                )
                            }
                            if let ssid = device.wifiSSID {
                                MMStatusPill(
                                    title: ssid,
                                    systemImage: "wifi",
                                    statusColor: .secondary
                                )
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 16) {
                    GlassCircleButton(title: "Find Phone", systemImage: "speaker.wave.3.fill", size: 44) {
                        device.findMyPhone()
                    }
                    GlassCircleButton(title: "Send Clipboard", systemImage: "doc.on.clipboard", size: 44) {
                        device.sendClipboard()
                    }
                    GlassCircleButton(title: "Send Files", systemImage: "arrow.up.doc.fill", size: 44) {
                        device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name))
                    }
                    if device.canLock {
                        GlassCircleButton(title: "Lock Phone", systemImage: "lock.fill", size: 44) {
                            device.lockDevice()
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    // MARK: - Notifications

    private var recentNotificationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Notifications")
                    .font(MMFont.cardTitle)
                Spacer()
                Button("View All") {
                    onSelectSection(.notifications)
                }
                .font(MMFont.caption)
                .buttonStyle(.link)
            }
            .padding(.horizontal, 4)

            MMCard(radius: 14) {
                VStack(spacing: 0) {
                    ForEach(Array(device.notifications.prefix(3).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 16) }
                        NotificationPreviewRow(item: item)
                    }
                }
            }
        }
    }

    // MARK: - Files

    private var recentFilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files & Transfers")
                    .font(MMFont.cardTitle)
                Spacer()
                Button("View All") {
                    onSelectSection(.files)
                }
                .font(MMFont.caption)
                .buttonStyle(.link)
            }
            .padding(.horizontal, 4)

            MMCard(radius: 14) {
                Group {
                    if device.transfers.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc")
                                .font(.title3)
                                .foregroundStyle(MMColor.electricCyanEnd)
                            Text("Drop files anywhere in this window to send them to \(device.name). Files sent to you are saved in Downloads.")
                                .font(MMFont.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(device.transfers.prefix(3).enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().padding(.leading, 16) }
                                TransferRow(item: item)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Now Playing

private struct NowPlayingPanel: View {
    @Bindable var device: DeviceViewModel
    @State private var draftVolume: Float = 0.5
    @State private var isEditingVolume = false

    var body: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    artwork

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.nowPlayingTitle ?? "Now Playing")
                            .font(MMFont.cardTitle)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(MMFont.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 18) {
                        Button("Previous", systemImage: "backward.fill") { device.previousMedia() }
                        Button(
                            device.nowPlayingIsPlaying ? "Pause" : "Play",
                            systemImage: device.nowPlayingIsPlaying ? "pause.fill" : "play.fill"
                        ) {
                            device.playPauseMedia()
                        }
                        .font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        Button("Next", systemImage: "forward.fill") { device.nextMedia() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title3)
                }

                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $draftVolume, in: 0...1) { Text("Volume") } onEditingChanged: { editing in
                        isEditingVolume = editing
                        if !editing { device.setVolume(draftVolume) }
                    }
                    .labelsHidden()
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(!device.canSetVolume)
            }
            .padding(18)
        }
        .onAppear { draftVolume = device.volume }
        .onChange(of: device.volume) {
            if !isEditingVolume { draftVolume = device.volume }
        }
    }

    private var subtitle: String? {
        let parts = [device.nowPlayingArtist, device.nowPlayingAlbum].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = device.albumArt {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Notification Preview Row

private struct NotificationPreviewRow: View {
    let item: PhoneNotification

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.appName)
                    .font(MMFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.date.formatted(.relative(presentation: .named)))
                    .font(MMFont.telemetrySmall)
                    .foregroundStyle(.secondary)
            }
            Text(item.title)
                .font(MMFont.bodyMedium)
                .lineLimit(1)
            if !item.text.isEmpty {
                Text(item.text)
                    .font(MMFont.body)
                    .lineLimit(2)
            }
            if let code = item.code {
                CopyCodeButton(code: code)
                    .buttonStyle(.link)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Remote Input Row

private struct RemoteInputRow: View {
    @State private var isTrusted = InputSynthesizer.shared.isAccessibilityTrusted
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Group {
            if !isTrusted {
                MMCard(radius: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.title2)
                            .foregroundStyle(MMColor.electricCyanEnd)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use phone as trackpad and keyboard")
                                .font(MMFont.cardTitle)
                            Text("MacMate requires Accessibility permission to move the mouse pointer and type from your phone.")
                                .font(MMFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Allow…") {
                            InputSynthesizer.shared.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MMColor.electricCyanEnd)
                        .controlSize(.small)
                    }
                    .padding(16)
                }
            }
        }
        .onChange(of: controlActiveState) {
            isTrusted = InputSynthesizer.shared.isAccessibilityTrusted
        }
    }
}
