//
//  DevicePane.swift
//  MacMate
//
//  Device identity, connection telemetry, certificate fingerprint verification,
//  hardware controls (Ping, Find Phone, Lock), and integrated Remote Commands.
//

import SwiftUI
import AppKit

public struct DevicePane: View {
    @Bindable var device: DeviceViewModel

    @State private var editingCommand: RemoteCommand?
    @State private var commandToDelete: RemoteCommand?
    @State private var isUnpairing = false
    @State private var pingFeedback = false
    @AppStorage(RunCommandPlugin.shortcutsKey) private var shareShortcuts = false

    public init(device: DeviceViewModel) {
        self.device = device
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(MMFont.hero)
                        Text(device.statusLine)
                            .font(MMFont.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MMStatusPill(
                        title: device.isConnected ? "Connected" : "Offline",
                        systemImage: device.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill",
                        statusColor: device.isConnected ? MMColor.statusConnected : MMColor.statusNeutral,
                        showPulse: device.isConnected
                    )
                }

                // Quick Hardware Actions
                quickActionsCard

                // Device Identity & Telemetry
                deviceTelemetryCard

                // Security & TLS Fingerprint
                securityCard

                // Remote Shell Commands (Folded from CommandsPane)
                commandsCard
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editingCommand) { command in
            CommandEditor(command: command) { device.saveCommand($0) }
        }
        .confirmationDialog(
            "Delete “\(commandToDelete?.name ?? "")”?",
            isPresented: Binding(get: { commandToDelete != nil }, set: { if !$0 { commandToDelete = nil } }),
            presenting: commandToDelete
        ) { command in
            Button("Delete", role: .destructive) { device.deleteCommand(id: command.id) }
        }
        .confirmationDialog(
            "Unpair \(device.name)?",
            isPresented: $isUnpairing
        ) {
            Button("Unpair", role: .destructive) { device.unpair() }
        } message: {
            Text("You will need to accept a new pairing request from \(device.name) to reconnect.")
        }
    }

    // MARK: - Quick Actions

    private var quickActionsCard: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Device Controls")
                    .font(MMFont.cardTitle)

                HStack(spacing: 12) {
                    Button(action: {
                        device.findMyPhone()
                    }) {
                        Label("Find Phone", systemImage: "speaker.wave.3.fill")
                            .font(MMFont.bodyMedium)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MMColor.electricCyanEnd)
                    .disabled(!device.isConnected)

                    if device.canLock {
                        Button(action: {
                            device.lockDevice()
                        }) {
                            Label("Lock Phone", systemImage: "lock.fill")
                                .font(MMFont.bodyMedium)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!device.isConnected)
                    }

                    Button(action: {
                        device.ping()
                        pingFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            pingFeedback = false
                        }
                    }) {
                        Label(pingFeedback ? "Ping Sent!" : "Ping", systemImage: pingFeedback ? "checkmark" : "antenna.radiowaves.left.and.right")
                            .font(MMFont.bodyMedium)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!device.isConnected)

                    Spacer()

                    Button("Unpair…", role: .destructive) {
                        isUnpairing = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
        }
    }

    // MARK: - Device Telemetry

    private var deviceTelemetryCard: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Telemetry & Hardware")
                    .font(MMFont.cardTitle)

                VStack(spacing: 10) {
                    telemetryRow(label: "Device Model", value: device.name, icon: "iphone")
                    Divider()
                    telemetryRow(
                        label: "Connection Link",
                        value: device.isViaTailscale ? "Tailscale Mesh VPN" : "Local Wi-Fi Network",
                        icon: device.isViaTailscale ? "point.3.connected.trianglepath.dotted" : "wifi"
                    )
                    Divider()
                    if let battery = device.batteryPercent {
                        telemetryRow(
                            label: "Battery Level",
                            value: "\(battery)% \(device.isCharging ? "(Charging)" : "")",
                            icon: DeviceSymbols.battery(battery, charging: device.isCharging)
                        )
                        Divider()
                    }
                    if let network = device.networkType, !network.isEmpty {
                        telemetryRow(label: "Cellular Network", value: network, icon: "cellularbars")
                        Divider()
                    }
                    if let ssid = device.wifiSSID {
                        telemetryRow(label: "Wi-Fi Network", value: ssid, icon: "wifi")
                        Divider()
                    }
                    telemetryRow(label: "Device ID", value: device.id, icon: "number")
                }
            }
            .padding(18)
        }
    }

    private func telemetryRow(label: String, value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(MMColor.electricCyanEnd)
                .frame(width: 20)
            Text(label)
                .font(MMFont.body)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(MMFont.telemetry)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Security & TLS Fingerprint

    private var securityCard: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("TLS Certificate Pinning", systemImage: "lock.shield.fill")
                        .font(MMFont.cardTitle)
                        .foregroundStyle(MMColor.statusConnected)
                    Spacer()
                    Text("SHA-256")
                        .font(MMFont.telemetrySmall)
                        .foregroundStyle(.secondary)
                }

                Text("Verify this fingerprint matches the fingerprint displayed in KDE Connect on your phone:")
                    .font(MMFont.caption)
                    .foregroundStyle(.secondary)

                if device.certificateFingerprint.isEmpty {
                    Text("No certificate fingerprint available.")
                        .font(MMFont.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let rows = FingerprintFormat.rows(device.certificateFingerprint)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows, id: \.self) { row in
                            Text(row)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                }
            }
            .padding(18)
        }
    }

    // MARK: - Remote Commands (Folded from CommandsPane)

    private var commandsCard: some View {
        MMCard(radius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remote Shell Commands")
                            .font(MMFont.cardTitle)
                        Text("\(device.name) can trigger these commands on this Mac via KDE Connect.")
                            .font(MMFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Command…") {
                        editingCommand = RemoteCommand(name: "", command: "")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if device.commands.isEmpty {
                    Text("No remote commands configured yet.")
                        .font(MMFont.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 8) {
                        ForEach(device.commands) { command in
                            commandRow(command: command)
                        }
                    }
                }

                Divider()

                Toggle(isOn: $shareShortcuts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Apple Shortcuts on phone")
                            .font(MMFont.bodyMedium)
                        Text("Allows \(device.name) to run your macOS Shortcuts remotely.")
                            .font(MMFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: shareShortcuts) {
                    MacMateService.shared.runCommandPlugin.refreshShortcuts()
                }
            }
            .padding(18)
        }
    }

    private func commandRow(command: RemoteCommand) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(MMFont.bodyMedium)
                Text(command.command)
                    .font(MMFont.telemetrySmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            Button("Run") {
                device.executeCommand(id: command.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Button("Edit…") { editingCommand = command }
                Button("Delete…", role: .destructive) { commandToDelete = command }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }
}

// MARK: - Command Editor

private struct CommandEditor: View {
    @State var command: RemoteCommand
    let onSave: (RemoteCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $command.name)
            TextField("Shell Command", text: $command.command)
                .font(.system(.body, design: .monospaced))
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 200)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(command)
                    dismiss()
                }
                .disabled(command.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                          command.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
