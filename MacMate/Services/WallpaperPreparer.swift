//
//  WallpaperPreparer.swift
//  MacMate
//
//  Captures the Mac's main-display wallpaper and prepares it for the
//  PocketLink `pocketlink.wallpaper` push: downscale via ImageIO, re-encode as
//  JPEG (80-85%), enforce PocketLink's hard byte/pixel caps, and compute the
//  SHA-256 of the exact bytes that will be sent.
//
//  Image bytes are never logged — only hash prefix, size, and outcome.
//

import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares a wallpaper image for sending to PocketLink.
///
/// All hard limits below are enforced by the PocketLink Android peer and must
/// never be exceeded by macmate.
public struct WallpaperPreparer {
    /// PocketLink hard caps (docs/WALLPAPER_SYNC_PROTOCOL.md §5).
    public static let maxTransferBytes: Int64 = 8 * 1024 * 1024   // 8 MB
    public static let maxImageSide: Int = 4096
    public static let maxTotalPixels: Int = 16 * 1024 * 1024      // 16 MP

    /// macmate targets (soft): stay under ~1 MB, longest side ~1600-1920 px.
    public static let targetMaxBytes: Int64 = 1_000_000
    public static let targetMaxSide: Int = 1792
    public static let jpegQuality: CGFloat = 0.82

    /// Prepared image, ready to hand to `PayloadUploader`.
    public struct Result: Sendable {
        public let data: Data
        public let mimeType: String
        public let width: Int
        public let height: Int
        public let sha256: String
        public let sourceURL: URL
    }

    /// Captures the primary screen's wallpaper via `NSWorkspace.desktopImageURL(for:)`.
    ///
    /// Uses `NSScreen.screens.first` (the primary display) rather than
    /// `NSScreen.main`, which follows keyboard focus and would flip the wallpaper
    /// between displays.
    ///
    /// Returns `nil` when there is no static file to send (dynamic/aerial/video
    /// wallpapers report no URL) or the file can't be read. Logs quietly and
    /// never crashes.
    public static func prepareMainScreenWallpaper() -> Result? {
        guard let screen = NSScreen.screens.first else {
            MacMateLog("[WallpaperPreparer] No screens; skipping wallpaper send")
            return nil
        }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            MacMateLog("[WallpaperPreparer] No static wallpaper file for main screen (dynamic/aerial/video); skipping")
            return nil
        }
        return prepareFile(url)
    }

    /// Reads and prepares a wallpaper file URL.
    public static func prepareFile(_ url: URL) -> Result? {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            MacMateLog("[WallpaperPreparer] Wallpaper file not readable: \(url.lastPathComponent)")
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            MacMateLog("[WallpaperPreparer] Wallpaper file could not be read: \(url.lastPathComponent)")
            return nil
        }
        return prepare(data, sourceURL: url)
    }

    /// Downscale + re-encode raw image bytes, enforcing PocketLink's hard caps.
    /// Returns `nil` if the source isn't a decodable image or the result can't
    /// be brought under the byte cap.
    public static func prepare(_ data: Data, sourceURL: URL) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            MacMateLog("[WallpaperPreparer] Wallpaper is not a decodable image: \(sourceURL.lastPathComponent)")
            return nil
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0

        if width > Self.maxImageSide || height > Self.maxImageSide {
            MacMateLog("[WallpaperPreparer] Wallpaper side \(max(width, height)) px exceeds cap; downscaling")
        }
        if width * height > Self.maxTotalPixels {
            MacMateLog("[WallpaperPreparer] Wallpaper \(width * height) px exceeds pixel cap; downscaling")
        }

        let isJPEG = type == UTType.jpeg.identifier
        let isPNG = type == UTType.png.identifier

        // Small, phone-acceptable source: send as-is (no re-encode needed).
        if data.count <= Int(Self.targetMaxBytes),
           (isJPEG || isPNG),
           width <= Self.maxImageSide, height <= Self.maxImageSide,
           width * height <= Self.maxTotalPixels {
            let mimeType = isJPEG ? "image/jpeg" : "image/png"
            let sha256 = sha256Hex(data)
            MacMateLog("[WallpaperPreparer] Kept wallpaper \(mimeType) \(width)x\(height) \(data.count) bytes sha \(sha256.prefix(12))...")
            return Result(data: data, mimeType: mimeType, width: width, height: height, sha256: sha256, sourceURL: sourceURL)
        }

        // Otherwise downscale via ImageIO and re-encode as JPEG.
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.targetMaxSide,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else {
            MacMateLog("[WallpaperPreparer] ImageIO thumbnail creation failed: \(sourceURL.lastPathComponent)")
            return nil
        }
        let outWidth = thumbnail.width
        let outHeight = thumbnail.height
        guard outWidth <= Self.maxImageSide, outHeight <= Self.maxImageSide,
              outWidth * outHeight <= Self.maxTotalPixels else {
            MacMateLog("[WallpaperPreparer] Downscaled wallpaper still exceeds PocketLink caps")
            return nil
        }

        let encoded = jpegEncode(thumbnail)
        guard encoded.count <= Int(Self.maxTransferBytes) else {
            MacMateLog("[WallpaperPreparer] Encoded wallpaper exceeds \(Self.maxTransferBytes) byte cap; skipping")
            return nil
        }

        let sha256 = sha256Hex(encoded)
        MacMateLog("[WallpaperPreparer] Prepared wallpaper image/jpeg \(outWidth)x\(outHeight) \(encoded.count) bytes sha \(sha256.prefix(12))...")
        return Result(data: encoded, mimeType: "image/jpeg", width: outWidth, height: outHeight, sha256: sha256, sourceURL: sourceURL)
    }

    // MARK: - Private

    private static func jpegEncode(_ image: CGImage) -> Data {
        let qualities: [CGFloat] = [jpegQuality, 0.70, 0.55, 0.40]
        for quality in qualities {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            let data = output as Data
            if data.count <= Int(Self.targetMaxBytes) { return data }
            // Keep the smallest attempt even if still over ~1 MB; the hard 8 MB
            // cap is checked by the caller.
        }
        // Fallback: encode once at the lowest quality and return it whatever its size.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: qualities.last ?? 0.40] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }

    private static func sha256Hex(_ data: Data) -> String {
        let bytes = Array(SHA256.hash(data: data))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
