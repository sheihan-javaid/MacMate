//
//  MainWindowView.swift
//  MacMate
//
//  The primary application window: modern persistent sidebar with branding,
//  active device telemetry, 10 primary workspace sections, and nearby discovery.
//

import SwiftUI

/// What the sidebar selects. Selecting a section on a device shows that section.
enum SidebarItem: Hashable {
    case device(String)
    case section(String, MacMateSection)

    var deviceId: String {
        switch self {
        case .device(let id), .section(let id, _): return id
        }
    }

    var section: MacMateSection {
        switch self {
        case .device: return .overview
        case .section(_, let section): return section
        }
    }

    init(deviceId: String, section: MacMateSection) {
        self = .section(deviceId, section)
    }
}

public struct MainWindowView: View {
    @Bindable var appModel: MacMateAppModel
    @State private var selection: SidebarItem?
    @State private var section: MacMateSection
    @AppStorage(MMAppearanceManager.key) private var appearancePreference = "system"

    public init(appModel: MacMateAppModel) {
        self.init(appModel: appModel, initialSection: .overview)
    }

    init(appModel: MacMateAppModel, initialSection: MacMateSection) {
        self.appModel = appModel
        _selection = State(initialValue: appModel.selectedDeviceId.map { SidebarItem.section($0, initialSection) })
        _section = State(initialValue: initialSection)
    }

    public var body: some View {
        NavigationSplitView {
            DeviceSidebar(appModel: appModel, selection: $selection, activeSection: $section) {
                appModel.isShowingConnectByIP = true
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .preferredColorScheme(MMAppearanceManager.currentScheme(from: appearancePreference))
        .frame(minWidth: 800, minHeight: 540)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $appModel.isShowingConnectByIP) {
            ConnectByIPSheet { await appModel.addManualPeer(address: $0) }
        }
        .sheet(item: pairRequestBinding) { request in
            PairRequestSheet(
                request: request,
                onAccept: { appModel.acceptIncomingPairRequest(request) },
                onDecline: { appModel.rejectIncomingPairRequest() }
            )
        }
        .onAppear {
            appModel.checkNotificationStatus()
            if selection == nil, let primaryId = appModel.selectedDeviceId {
                selection = .section(primaryId, section)
            }
        }
        .onChange(of: selection) {
            if let selected = selection {
                if selected.deviceId != appModel.selectedDeviceId {
                    appModel.selectedDeviceId = selected.deviceId
                }
                if selected.section != section {
                    section = selected.section
                }
            }
        }
        .onChange(of: appModel.selectedDeviceId) {
            if let deviceId = appModel.selectedDeviceId {
                if selection?.deviceId != deviceId {
                    selection = .section(deviceId, section)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let currentDeviceId = appModel.selectedDeviceId ?? appModel.allDevices.first?.id,
           let device = appModel.allDevices.first(where: { $0.id == currentDeviceId }) {
            DeviceDetailView(
                device: device,
                appModel: appModel,
                section: device.isConnected ? section : .overview,
                onSelectSection: { newSection in
                    section = newSection
                    selection = .section(device.id, newSection)
                },
                onConnectByIP: { appModel.isShowingConnectByIP = true }
            )
        } else if appModel.allDevices.isEmpty {
            OnboardingView(appModel: appModel) {
                appModel.isShowingConnectByIP = true
            }
        } else {
            ContentUnavailableView("No Device Selected", systemImage: "macbook.and.iphone", description: Text("Choose an Android device in the sidebar."))
        }
    }

    /// The sheet can only be closed by answering it, which clears the request in the model.
    private var pairRequestBinding: Binding<PairRequestViewModel?> {
        Binding(get: { appModel.incomingPairRequest }, set: { _ in })
    }
}

// MARK: - Sidebar

struct DeviceSidebar: View {
    let appModel: MacMateAppModel
    @Binding var selection: SidebarItem?
    @Binding var activeSection: MacMateSection
    let onConnectByIP: () -> Void

    @State private var deviceToUnpair: DeviceViewModel?

    private var activeDevice: DeviceViewModel? {
        if let selId = selection?.deviceId, let dev = appModel.allDevices.first(where: { $0.id == selId }) {
            return dev
        }
        return appModel.pairedDevices.first ?? appModel.availableDevices.first
    }

    var body: some View {
        List(selection: $selection) {
            // Sidebar Header Branding
            Section {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(MMColor.accentPrimaryGradient)
                            .frame(width: 30, height: 30)
                            .shadow(color: MMColor.electricCyanStart.opacity(0.3), radius: 4, x: 0, y: 2)

                        Image(systemName: "macbook.and.iphone")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("MacMate")
                            .font(MMFont.cardTitle)
                            .foregroundStyle(.primary)
                        Text("Your Mac and Android, in sync.")
                            .font(MMFont.telemetrySmall)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Active Device & Navigation
            if let device = activeDevice {
                Section {
                    // Device Telemetry Chip
                    MMDeviceTelemetryChip(
                        deviceName: device.name,
                        isConnected: device.isConnected,
                        batteryPercent: device.batteryPercent,
                        isCharging: device.isCharging,
                        linkType: device.isViaTailscale ? "Tailscale" : (device.isConnected ? "Wi-Fi" : "Offline")
                    )
                    .padding(.vertical, 4)
                    .contextMenu { contextMenu(for: device) }
                }

                Section("Navigation") {
                    ForEach(MacMateSection.primarySections) { sec in
                        NavigationRow(
                            section: sec,
                            device: device,
                            badge: badgeCount(for: sec, device: device)
                        )
                        .tag(SidebarItem.section(device.id, sec))
                    }
                }
            }

            // Other Paired Devices
            if appModel.pairedDevices.count > 1 {
                Section("My Devices") {
                    ForEach(appModel.pairedDevices) { dev in
                        if dev.id != activeDevice?.id {
                            Button(action: {
                                appModel.selectedDeviceId = dev.id
                                selection = .section(dev.id, activeSection)
                            }) {
                                HStack {
                                    Image(systemName: dev.deviceType.systemImageName)
                                        .foregroundStyle(dev.isConnected ? MMColor.statusConnected : .secondary)
                                    Text(dev.name)
                                        .font(MMFont.body)
                                    Spacer()
                                    if let battery = dev.batteryPercent {
                                        Text("\(battery)%")
                                            .font(MMFont.telemetrySmall)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: dev) }
                        }
                    }
                }
            }

            // Nearby Unpaired Devices
            if !appModel.availableDevices.isEmpty {
                Section("Nearby") {
                    ForEach(appModel.availableDevices) { device in
                        HStack {
                            Image(systemName: device.deviceType.systemImageName)
                                .foregroundStyle(.secondary)
                            Text(device.name)
                                .font(MMFont.body)
                            Spacer()
                            Button("Pair") {
                                device.pair()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .tag(SidebarItem.device(device.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onConnectByIP) {
                Label("Connect by Address…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .confirmationDialog(
            "Unpair \(deviceToUnpair?.name ?? "device")?",
            isPresented: Binding(get: { deviceToUnpair != nil }, set: { if !$0 { deviceToUnpair = nil } }),
            presenting: deviceToUnpair
        ) { device in
            Button("Unpair", role: .destructive) { device.unpair() }
        } message: { device in
            Text("You'll need to pair again from \(device.name) to reconnect.")
        }
    }

    private func badgeCount(for section: MacMateSection, device: DeviceViewModel) -> Int {
        switch section {
        case .notifications: return device.notifications.count
        case .messages: return device.smsThreads.reduce(0) { $0 + $1.unreadCount }
        case .files: return device.activeTransferCount
        default: return 0
        }
    }

    @ViewBuilder
    private func contextMenu(for device: DeviceViewModel) -> some View {
        if device.isConnected {
            Button("Find Phone", systemImage: "speaker.wave.3") { device.findMyPhone() }
            Button("Send Files…", systemImage: "square.and.arrow.up") {
                device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name))
            }
            Divider()
        }
        Button("Unpair…", systemImage: "link.badge.minus", role: .destructive) { deviceToUnpair = device }
    }
}

// MARK: - Navigation Row

private struct NavigationRow: View {
    let section: MacMateSection
    let device: DeviceViewModel
    var badge: Int = 0

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.systemImage)
                .font(MMFont.body)

            Spacer()

            if badge > 0 {
                Text("\(badge)")
                    .font(MMFont.telemetrySmall)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
    }
}

// MARK: - Menu Commands

struct MacMateCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appModel: MacMateAppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MacMate") { MacMateCredits.showAboutPanel() }
            Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
        }

        CommandGroup(after: .newItem) {
            Button("Connect by Address…") {
                openWindow(id: "main")
                appModel.isShowingConnectByIP = true
            }
            .keyboardShortcut("k")

            Button("Look for Devices") { appModel.refreshDiscovery() }
                .keyboardShortcut("r")
        }

        CommandMenu("Device") {
            let device = appModel.primaryDevice
            Button("Send Files…") {
                if let device { device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name)) }
            }
            .keyboardShortcut("o")
            .disabled(device == nil)

            Button("Send Clipboard") { device?.sendClipboard() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(device == nil)

            Divider()

            Button("Find Phone") { device?.findMyPhone() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(device == nil)

            if device?.canLock == true {
                Button("Lock") { device?.lockDevice() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            Button("Ping") { device?.ping() }
                .disabled(device == nil)
        }
    }
}

/// Backward compatibility alias
typealias TetherCommands = MacMateCommands

