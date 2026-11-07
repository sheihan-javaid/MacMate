//
//  AppIconResolver.swift
//  MacMate
//
//  Resolves or generates a 256x256 app tile for notifications that have no photo.
//

import AppKit
import CoreGraphics
import CoreText
import UniformTypeIdentifiers

public final class AppIconResolver: @unchecked Sendable {
    public static let shared = AppIconResolver()

    private let dataCache = NSCache<NSString, NSData>()
    private let imageCache = NSCache<NSString, NSImage>()

    public init() {
        dataCache.countLimit = 128
        dataCache.totalCostLimit = 8 * 1024 * 1024
        imageCache.countLimit = 128
        imageCache.totalCostLimit = 16 * 1024 * 1024
    }

    // MARK: - Cache Keys

    /// Produces distinct cache keys for package identities ("pkg:<package>") and
    /// fallback app names ("app:<normalized_name>").
    public static func cacheKey(forPackage package: String?, appName: String) -> NSString {
        if let package = package?.trimmingCharacters(in: .whitespacesAndNewlines),
           !package.isEmpty,
           NativeNotificationFilter.isValidPackageName(package) {
            return "pkg:\(package.lowercased())" as NSString
        } else {
            return "app:\(NotificationAppKey.normalizeAppName(appName))" as NSString
        }
    }

    // MARK: - Public API

    /// Returns a 256x256 PNG representation of the application tile.
    public func tile(forPackage package: String?, appName: String) -> Data {
        let key = Self.cacheKey(forPackage: package, appName: appName)
        if let cached = dataCache.object(forKey: key) {
            return cached as Data
        }

        let normalizedPackage = package?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pngData = renderTile(package: normalizedPackage, appName: appName)
        dataCache.setObject(pngData as NSData, forKey: key, cost: pngData.count)
        return pngData
    }

    /// Returns the application tile decoded as an NSImage, cached in an in-memory NSCache.
    public func tileImage(forPackage package: String?, appName: String) -> NSImage? {
        let key = Self.cacheKey(forPackage: package, appName: appName)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        let data = tile(forPackage: package, appName: appName)
        guard let image = NSImage(data: data) else { return nil }
        let cost = max(1, Int(image.size.width * image.size.height * 4))
        imageCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    public func removeAll() {
        dataCache.removeAllObjects()
        imageCache.removeAllObjects()
    }

    // MARK: - Color Palette & Hash

    /// Curated palette of 16 high-contrast, accessible colors.
    public static let palette: [UInt32] = [
        0x5856D6, // Indigo
        0x007AFF, // Blue
        0x32ADE6, // Cyan
        0x30B0C7, // Teal
        0x00C7BE, // Mint
        0x34C759, // Green
        0x28CD41, // Emerald
        0xFF9500, // Orange
        0xFF3B30, // Crimson
        0xFF6482, // Coral
        0xFF2D55, // Rose
        0xAF52DE, // Purple
        0x8944AB, // Violet
        0x636366, // Slate
        0xA2845E, // Brown
        0x306346  // Forest
    ]

    /// 64-bit FNV-1a hash over UTF-8 bytes.
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }

    // MARK: - Brand Table

    private struct BrandSpec {
        let name: String
        let backgroundColor: UInt32
        let isDarkLogo: Bool
        let path: (CGRect) -> CGPath
    }

    private static let brandTable: [String: BrandSpec] = [
        "com.whatsapp": BrandSpec(name: "WhatsApp", backgroundColor: 0x25D366, isDarkLogo: false, path: whatsAppPath),
        "com.whatsapp.w4b": BrandSpec(name: "WhatsApp Business", backgroundColor: 0x25D366, isDarkLogo: false, path: whatsAppPath),
        "com.linkedin.android": BrandSpec(name: "LinkedIn", backgroundColor: 0x0A66C2, isDarkLogo: false, path: linkedInPath),
        "com.instagram.android": BrandSpec(name: "Instagram", backgroundColor: 0xE4405F, isDarkLogo: false, path: instagramPath),
        "com.google.android.gm": BrandSpec(name: "Gmail", backgroundColor: 0xEA4335, isDarkLogo: false, path: gmailPath),
        "org.telegram.messenger": BrandSpec(name: "Telegram", backgroundColor: 0x26A5E4, isDarkLogo: false, path: telegramPath),
        "com.slack": BrandSpec(name: "Slack", backgroundColor: 0x4A154B, isDarkLogo: false, path: slackPath),
        "com.spotify.music": BrandSpec(name: "Spotify", backgroundColor: 0x1ED760, isDarkLogo: false, path: spotifyPath),
        "com.snapchat.android": BrandSpec(name: "Snapchat", backgroundColor: 0xFFFC00, isDarkLogo: true, path: snapchatPath)
    ]

    // MARK: - Brand CGPaths (Simple Icons)

    /// Source: Simple Icons (WhatsApp) - Speech bubble with telephone receiver contour.
    public static func whatsAppPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = rect.width / 24.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        path.move(to: p(12, 2.5))
        path.addCurve(to: p(21.5, 12), control1: p(17.2, 2.5), control2: p(21.5, 6.8))
        path.addCurve(to: p(12, 21.5), control1: p(21.5, 17.2), control2: p(17.2, 21.5))
        path.addCurve(to: p(7.5, 20.2), control1: p(10.4, 21.5), control2: p(8.9, 21.0))
        path.addLine(to: p(3.0, 22.0))
        path.addLine(to: p(4.8, 17.8))
        path.addCurve(to: p(2.5, 12), control1: p(3.3, 16.1), control2: p(2.5, 14.1))
        path.addCurve(to: p(12, 2.5), control1: p(2.5, 6.8), control2: p(6.8, 2.5))
        path.closeSubpath()
        return path
    }

    /// Source: Simple Icons (LinkedIn) - Clean "in" ligature glyph.
    public static func linkedInPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = rect.width / 24.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        // "i" dot
        path.addEllipse(in: CGRect(x: rect.minX + 3.2 * s, y: rect.minY + 16.8 * s, width: 3.6 * s, height: 3.6 * s))
        // "i" stem
        path.addRoundedRect(in: CGRect(x: rect.minX + 3.4 * s, y: rect.minY + 3.0 * s, width: 3.2 * s, height: 11.5 * s), cornerWidth: 0.5 * s, cornerHeight: 0.5 * s)
        // "n" stem
        path.addRoundedRect(in: CGRect(x: rect.minX + 9.0 * s, y: rect.minY + 3.0 * s, width: 3.2 * s, height: 11.5 * s), cornerWidth: 0.5 * s, cornerHeight: 0.5 * s)
        // "n" arch and right stem
        let nPath = CGMutablePath()
        nPath.move(to: p(12.2, 11.0))
        nPath.addCurve(to: p(16.0, 14.5), control1: p(13.2, 13.5), control2: p(14.5, 14.5))
        nPath.addCurve(to: p(19.8, 12.0), control1: p(18.0, 14.5), control2: p(19.8, 13.5))
        nPath.addLine(to: p(19.8, 3.0))
        nPath.addLine(to: p(16.8, 3.0))
        nPath.addLine(to: p(16.8, 10.5))
        nPath.addCurve(to: p(15.0, 11.8), control1: p(16.8, 11.5), control2: p(16.0, 11.8))
        nPath.addCurve(to: p(12.2, 10.0), control1: p(13.8, 11.8), control2: p(12.2, 11.0))
        nPath.closeSubpath()
        path.addPath(nPath)
        return path
    }

    /// Source: Simple Icons (Instagram) - Camera body, lens, and flash.
    public static func instagramPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = rect.width / 24.0
        let outer = CGPath(roundedRect: rect.insetBy(dx: 2 * s, dy: 2 * s), cornerWidth: 5.5 * s, cornerHeight: 5.5 * s, transform: nil)
        let inner = CGPath(roundedRect: rect.insetBy(dx: 4.2 * s, dy: 4.2 * s), cornerWidth: 3.5 * s, cornerHeight: 3.5 * s, transform: nil)
        path.addPath(outer)
        path.addPath(inner)
        let lensOuter = CGPath(ellipseIn: CGRect(x: rect.midX - 5.5 * s, y: rect.midY - 5.5 * s, width: 11 * s, height: 11 * s), transform: nil)
        let lensInner = CGPath(ellipseIn: CGRect(x: rect.midX - 3.5 * s, y: rect.midY - 3.5 * s, width: 7 * s, height: 7 * s), transform: nil)
        path.addPath(lensOuter)
        path.addPath(lensInner)
        let flash = CGPath(ellipseIn: CGRect(x: rect.minX + 17.5 * s, y: rect.minY + 17.5 * s, width: 2.2 * s, height: 2.2 * s), transform: nil)
        path.addPath(flash)
        return path
    }

    /// Source: Simple Icons (Gmail) - Folded envelope M-crest.
    public static func gmailPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = rect.width / 24.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        path.move(to: p(2.5, 4.0))
        path.addLine(to: p(6.5, 4.0))
        path.addLine(to: p(6.5, 14.5))
        path.addLine(to: p(12.0, 10.2))
        path.addLine(to: p(17.5, 14.5))
        path.addLine(to: p(17.5, 4.0))
        path.addLine(to: p(21.5, 4.0))
        path.addLine(to: p(21.5, 19.5))
        path.addLine(to: p(18.5, 19.5))
        path.addLine(to: p(12.0, 14.5))
        path.addLine(to: p(5.5, 19.5))
        path.addLine(to: p(2.5, 19.5))
        path.closeSubpath()
        return path
    }

    /// Source: Simple Icons (Telegram) - Paper airplane.
    public static func telegramPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = rect.width / 24.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        path.move(to: p(21.8, 20.8))
        path.addLine(to: p(18.5, 5.0))
        path.addLine(to: p(2.5, 11.2))
        path.addLine(to: p(8.0, 14.8))
        path.addLine(to: p(17.0, 9.2))
        path.addLine(to: p(9.8, 16.2))
        path.addLine(to: p(9.5, 20.5))
        path.addLine(to: p(12.8, 17.5))
        path.addLine(to: p(17.2, 20.8))
        path.closeSubpath()
        return path
    }

    /// Source: Simple Icons (Slack) - 4 directional lozenges and teardrops.
    public static func slackPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = rect.width / 24.0
        path.addRoundedRect(in: CGRect(x: rect.minX + 9.5 * s, y: rect.minY + 14.5 * s, width: 2.2 * s, height: 5.5 * s), cornerWidth: 1.1 * s, cornerHeight: 1.1 * s)
        path.addEllipse(in: CGRect(x: rect.minX + 14.5 * s, y: rect.minY + 16.2 * s, width: 2.2 * s, height: 2.2 * s))
        path.addRoundedRect(in: CGRect(x: rect.minX + 12.5 * s, y: rect.minY + 9.5 * s, width: 5.5 * s, height: 2.2 * s), cornerWidth: 1.1 * s, cornerHeight: 1.1 * s)
        path.addEllipse(in: CGRect(x: rect.minX + 14.2 * s, y: rect.minY + 4.5 * s, width: 2.2 * s, height: 2.2 * s))
        path.addRoundedRect(in: CGRect(x: rect.minX + 12.3 * s, y: rect.minY + 4.0 * s, width: 2.2 * s, height: 5.5 * s), cornerWidth: 1.1 * s, cornerHeight: 1.1 * s)
        path.addEllipse(in: CGRect(x: rect.minX + 7.3 * s, y: rect.minY + 5.6 * s, width: 2.2 * s, height: 2.2 * s))
        path.addRoundedRect(in: CGRect(x: rect.minX + 6.0 * s, y: rect.minY + 12.3 * s, width: 5.5 * s, height: 2.2 * s), cornerWidth: 1.1 * s, cornerHeight: 1.1 * s)
        path.addEllipse(in: CGRect(x: rect.minX + 7.6 * s, y: rect.minY + 17.3 * s, width: 2.2 * s, height: 2.2 * s))
        return path
    }

    /// Source: Simple Icons (Spotify) - 3 soundwave arcs.
    public static func spotifyPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = rect.width / 24.0
        func addWave(yOffset: CGFloat, width: CGFloat, thickness: CGFloat) {
            let wave = CGMutablePath()
            let startX = rect.midX - width * s / 2
            let endX = rect.midX + width * s / 2
            let baseY = rect.minY + yOffset * s
            wave.move(to: CGPoint(x: startX, y: baseY + 2.5 * s))
            wave.addCurve(
                to: CGPoint(x: endX, y: baseY + 2.5 * s),
                control1: CGPoint(x: rect.midX - width * s * 0.25, y: baseY + 5.5 * s),
                control2: CGPoint(x: rect.midX + width * s * 0.25, y: baseY + 5.5 * s)
            )
            let stroked = wave.copy(strokingWithWidth: thickness * s, lineCap: .round, lineJoin: .round, miterLimit: 10)
            path.addPath(stroked)
        }
        addWave(yOffset: 12.5, width: 15.0, thickness: 2.8)
        addWave(yOffset: 7.5, width: 12.5, thickness: 2.5)
        addWave(yOffset: 2.5, width: 10.0, thickness: 2.2)
        return path
    }

    /// Source: Simple Icons (Snapchat) - Ghost silhouette.
    public static func snapchatPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = rect.width / 24.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        path.move(to: p(12, 21.5))
        path.addCurve(to: p(17.5, 16.5), control1: p(15.5, 21.5), control2: p(17.5, 19.5))
        path.addCurve(to: p(16.5, 13.0), control1: p(17.5, 14.5), control2: p(17.0, 13.5))
        path.addCurve(to: p(21.5, 11.5), control1: p(18.5, 13.0), control2: p(21.5, 12.0))
        path.addCurve(to: p(18.5, 9.5), control1: p(21.5, 10.5), control2: p(20.0, 9.8))
        path.addCurve(to: p(19.5, 5.5), control1: p(19.0, 8.0), control2: p(19.5, 6.5))
        path.addCurve(to: p(12.0, 3.5), control1: p(17.5, 4.0), control2: p(15.0, 3.5))
        path.addCurve(to: p(4.5, 5.5), control1: p(9.0, 3.5), control2: p(6.5, 4.0))
        path.addCurve(to: p(5.5, 9.5), control1: p(4.5, 6.5), control2: p(5.0, 8.0))
        path.addCurve(to: p(2.5, 11.5), control1: p(4.0, 9.8), control2: p(2.5, 10.5))
        path.addCurve(to: p(7.5, 13.0), control1: p(2.5, 12.0), control2: p(5.5, 13.0))
        path.addCurve(to: p(6.5, 16.5), control1: p(7.0, 13.5), control2: p(6.5, 14.5))
        path.addCurve(to: p(12, 21.5), control1: p(6.5, 19.5), control2: p(8.5, 21.5))
        path.closeSubpath()
        return path
    }

    // MARK: - Tile Rendering

    private func renderTile(package: String?, appName: String) -> Data {
        let side = 256
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Data()
        }

        let brand = package.flatMap { Self.brandTable[$0] }
        let bgColor: CGColor
        if let brand {
            bgColor = Self.cgColor(hex: brand.backgroundColor)
        } else {
            let key = package ?? appName
            let hash = Self.fnv1a64(key)
            let colorHex = Self.palette[Int(hash % UInt64(Self.palette.count))]
            bgColor = Self.cgColor(hex: colorHex)
        }

        // 1. Draw rounded squircle background (~22% corner radius)
        let tileRect = CGRect(x: 0, y: 0, width: side, height: side)
        let cornerRadius = CGFloat(side) * 0.22
        let backgroundPath = CGPath(roundedRect: tileRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(backgroundPath)
        context.setFillColor(bgColor)
        context.fillPath()

        // 2. Draw brand logo or monogram letter
        let innerRect = CGRect(x: 56, y: 56, width: 144, height: 144)
        if let brand {
            let logoPath = brand.path(innerRect)
            context.addPath(logoPath)
            context.setFillColor(brand.isDarkLogo ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
            context.fillPath()
        } else {
            drawMonogram(in: context, side: side, appName: appName, package: package)
        }

        guard let cgImage = context.makeImage() else { return Data() }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private func drawMonogram(in context: CGContext, side: Int, appName: String, package: String?) {
        let char = appName.first(where: { $0.isLetter || $0.isNumber })
            ?? package?.split(separator: ".").last?.first(where: { $0.isLetter || $0.isNumber })
            ?? "?"
        let letter = String(char).uppercased()

        let baseFont = NSFont.systemFont(ofSize: 124, weight: .bold)
        let font: NSFont
        if let desc = baseFont.fontDescriptor.withDesign(.rounded), let rounded = NSFont(descriptor: desc, size: 124) {
            font = rounded
        } else {
            font = baseFont
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attrString = NSAttributedString(string: letter, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let textX = (CGFloat(side) - bounds.width) / 2.0 - bounds.minX
        let textY = (CGFloat(side) - bounds.height) / 2.0 - bounds.minY
        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)
    }

    private static func cgColor(hex: UInt32) -> CGColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

