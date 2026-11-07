//
//  FilesPane.swift
//  MacMate
//
//  Send and receive files with your phone, manage phone drive mounts,
//  and preview transferred files using native Quick Look (F-08).
//

import SwiftUI
import AppKit
import QuickLook

public struct FilesPane: View {
    let device: DeviceViewModel
    @State private var selectedQuickLookURL: URL?

    public init(device: DeviceViewModel) {
        self.device = device
    }

    public var body: some View {
        Group {
            if !device.isConnected {
                MMSectionGate(
                    state: .noDevice,
                    sectionTitle: "Files",
                    systemImage: "folder"
                ) { EmptyView() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // Header
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Files")
                                    .font(MMFont.hero)
                                Text("Send files to \(device.name), or drop them anywhere in this window.")
                                    .font(MMFont.body)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose Files…") {
                                device.sendFiles(FilePicker.chooseFiles(sendingTo: device.name))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MMColor.electricCyanEnd)
                        }

                        // Phone Drive in Finder
                        PhoneDriveSection(device: device)

                        // File Transfers
                        transfersSection
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .quickLookPreview($selectedQuickLookURL)
    }

    private var transfersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transfers")
                    .font(MMFont.cardTitle)
                Spacer()
                Button("Open Downloads Folder") {
                    if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                        NSWorkspace.shared.open(downloads)
                    }
                }
                .font(MMFont.caption)
                .buttonStyle(.link)
            }
            .padding(.horizontal, 4)

            MMCard(radius: 14) {
                if device.transfers.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Nothing sent or received yet.")
                            .font(MMFont.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(device.transfers.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 56) }
                            TransferRow(item: item, onQuickLook: { url in
                                selectedQuickLookURL = url
                            })
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Phone Drive Section

private struct PhoneDriveSection: View {
    let device: DeviceViewModel
    @Bindable private var files = PhoneFilesController.shared

    var body: some View {
        let state = files.driveState(for: device.id)
        MMCard(radius: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(state == .mounted ? MMColor.statusConnected.opacity(0.12) : Color.secondary.opacity(0.1))
                        .frame(width: 40, height: 40)

                    Image(systemName: state == .mounted ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                        .font(.system(size: 20))
                        .foregroundStyle(state == .mounted ? MMColor.statusConnected : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: state))
                        .font(MMFont.cardTitle)
                    Text(detail(for: state))
                        .font(MMFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    switch state {
                    case .mounted:
                        Button("Eject") { files.eject(device.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Show in Finder") { files.showInFinder(device.id) }
                            .buttonStyle(.borderedProminent)
                            .tint(MMColor.electricCyanEnd)
                            .controlSize(.small)
                    case .ejected, .failed:
                        Button("Mount") { files.mountAgain(device.id) }
                            .buttonStyle(.borderedProminent)
                            .tint(MMColor.electricCyanEnd)
                            .controlSize(.small)
                    case .turnedOff:
                        Button("Turn On") { files.isEnabled = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    case .mounting:
                        ProgressView().controlSize(.small)
                    case .notConnected:
                        EmptyView()
                    }
                }
            }
            .padding(16)
        }
    }

    private func title(for state: PhoneFilesController.DriveState) -> String {
        switch state {
        case .mounted: return "Mounted in Finder"
        case .mounting: return "Mounting…"
        case .ejected: return "Ejected"
        case .failed: return "Couldn't mount"
        case .turnedOff: return "Turned off"
        case .notConnected: return "Not connected"
        }
    }

    private func detail(for state: PhoneFilesController.DriveState) -> String {
        switch state {
        case .mounted: return "\(device.name)'s storage is accessible as a native drive in Finder."
        case .mounting: return "Connecting to \(device.name)'s storage…"
        case .ejected: return "Drive was ejected. Mount again or reconnect to restore."
        case .failed(let reason): return reason
        case .turnedOff: return "Drive mounting is disabled in Settings."
        case .notConnected: return "The drive appears when \(device.name) connects."
        }
    }
}

// MARK: - Transfer Row (F-08 Quick Look)

public struct TransferRow: View {
    let item: TransferItem
    var onQuickLook: ((URL) -> Void)? = nil

    public init(item: TransferItem, onQuickLook: ((URL) -> Void)? = nil) {
        self.item = item
        self.onQuickLook = onQuickLook
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcon.image(for: item.filename))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(MMFont.bodyMedium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.status == .transferring {
                    ProgressView(value: item.progress)
                        .controlSize(.small)
                }

                Text(detail)
                    .font(MMFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if let url = item.localURL, item.status == .completed {
                NSWorkspace.shared.open(url)
            }
        }
        .contextMenu {
            if let url = item.localURL {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Quick Look") { onQuickLook?(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private var detail: String {
        let direction = item.direction == .incoming ? "From \(item.deviceName)" : "To \(item.deviceName)"
        let size = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
        switch item.status {
        case .transferring:
            let done = ByteCountFormatter.string(fromByteCount: item.transferredBytes, countStyle: .file)
            return "\(direction) · \(done) of \(size)"
        case .failed(let reason):
            return "\(direction) · Failed: \(reason)"
        case .queued:
            return "\(direction) · Waiting"
        case .cancelled:
            return "\(direction) · Cancelled"
        case .completed:
            return "\(direction) · \(size) · \(item.timestamp.formatted(.relative(presentation: .named)))"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case .transferring:
            Text(item.progress, format: .percent.precision(.fractionLength(0)))
                .font(MMFont.telemetry)
                .foregroundStyle(.secondary)
        case .completed:
            if let url = item.localURL {
                HStack(spacing: 8) {
                    Button(action: { onQuickLook?(url) }) {
                        Image(systemName: "eye.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .imageScale(.large)
                    .foregroundStyle(MMColor.electricCyanEnd)
                    .help("Quick Look preview")

                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                        Image(systemName: "magnifyingglass.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .help("Show in Finder")
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MMColor.statusConnected)
                    .accessibilityLabel("Sent")
            }
        case .failed(let reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MMColor.statusWarning)
                .help(reason)
                .accessibilityLabel("Failed: \(reason)")
        case .queued, .cancelled:
            EmptyView()
        }
    }
}
