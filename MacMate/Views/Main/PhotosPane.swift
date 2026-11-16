//
//  PhotosPane.swift
//  MacMate
//
//  A native media browsing experience over the phone's mounted filesystem.
//  Indexes DCIM/Camera and Pictures when the phone's drive is mounted via SFTP or ADB.
//

import SwiftUI
import ImageIO
import AppKit
import QuickLook

public struct PhotosPane: View {
    let device: DeviceViewModel
    @Bindable private var files = PhoneFilesController.shared

    @State private var mediaFiles: [URL] = []
    @State private var isLoading = false
    @State private var selectedPreviewURL: URL?
    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)
    ]

    public init(device: DeviceViewModel) {
        self.device = device
    }

    private var driveState: PhoneFilesController.DriveState {
        files.driveState(for: device.id)
    }

    private var filteredMedia: [URL] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return mediaFiles }
        return mediaFiles.filter { $0.lastPathComponent.lowercased().contains(query) }
    }

    public var body: some View {
        Group {
            if !device.isConnected {
                MMSectionGate(
                    state: .noDevice,
                    sectionTitle: "Photos",
                    systemImage: "photo.on.rectangle"
                ) { EmptyView() }
            } else if driveState != .mounted {
                MMSectionGate(
                    state: .storageNotMounted(canMount: true),
                    sectionTitle: "Photos",
                    systemImage: "photo.on.rectangle",
                    primaryActionTitle: driveState == .mounting ? "Mounting…" : "Mount Phone Storage",
                    onPrimaryAction: {
                        files.mountAgain(device.id)
                    }
                ) { EmptyView() }
            } else {
                contentView
            }
        }
        .task(id: "\(device.id)_\(driveState)") {
            if driveState == .mounted {
                await loadMedia()
            }
        }
        .quickLookPreview($selectedPreviewURL)
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photos")
                        .font(MMFont.sectionHeader)
                    Text("\(mediaFiles.count) items on \(device.name)")
                        .font(MMFont.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: { Task { await loadMedia() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { files.showInFinder(device.id) }) {
                    Label("Open in Finder", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }

            if mediaFiles.isEmpty && !isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No Photos Found")
                        .font(MMFont.cardTitle)
                    Text("No pictures found in DCIM or Pictures on \(device.name)'s mounted drive.")
                        .font(MMFont.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("Reveal Drive in Finder") {
                        files.showInFinder(device.id)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredMedia, id: \.self) { url in
                            PhotoThumbnailCell(url: url)
                                .onTapGesture(count: 2) {
                                    NSWorkspace.shared.open(url)
                                }
                                .onTapGesture(count: 1) {
                                    selectedPreviewURL = url
                                }
                                .contextMenu {
                                    Button("Open with Preview") { NSWorkspace.shared.open(url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Button("Quick Look") { selectedPreviewURL = url }
                                }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func loadMedia() async {
        guard let mountPoint = files.mountPoint(for: device.id) else { return }
        isLoading = true
        defer { isLoading = false }

        let scanned = await Task.detached(priority: .userInitiated) { () -> [URL] in
            let fm = FileManager.default
            let candidateDirectories = [
                mountPoint.appendingPathComponent("DCIM/Camera"),
                mountPoint.appendingPathComponent("DCIM"),
                mountPoint.appendingPathComponent("Pictures")
            ]

            let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "mp4", "mov"]
            var results: [URL] = []

            for dir in candidateDirectories {
                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                        results.append(fileURL)
                        if results.count >= 200 { break } // Bounded scan for responsiveness
                    }
                }
                if results.count >= 200 { break }
            }

            // Sort by modification date descending
            return results.sorted { (u1, u2) -> Bool in
                let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
        }.value

        self.mediaFiles = scanned
    }
}

// MARK: - Thumbnail Cell

private final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 32 * 1024 * 1024 // 32 MB
    }

    func image(for path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    func setImage(_ image: NSImage, for path: String, cost: Int) {
        cache.setObject(image, forKey: path as NSString, cost: cost)
    }
}

private struct PhotoThumbnailCell: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if isVideo {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "video.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.6), in: Circle())
                            Spacer()
                        }
                        .padding(6)
                    }
                }
            }
            .frame(height: 110)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }

            Text(url.lastPathComponent)
                .font(MMFont.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .onDrag {
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .task(id: url.path) {
            if let cached = ThumbnailCache.shared.image(for: url.path) {
                thumbnail = cached
                return
            }

            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                // ImageIO decodes straight to thumbnail size; NSImage would decode
                // the whole photo (often 12 MP, sometimes over the phone mount) first.
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 560,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil }
                let thumb = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
                ThumbnailCache.shared.setImage(thumb, for: url.path, cost: cgImage.width * cgImage.height * 4)
                return thumb
            }.value

            if !Task.isCancelled {
                thumbnail = loaded
            }
        }
    }

    private var isVideo: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mp4" || ext == "mov"
    }
}

