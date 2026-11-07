import AppKit
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

/// KDE Connect sends notification artwork (often a contact photo), not a
/// guaranteed application logo. Never reuse it by app name or package name.
final class NotificationImages {
    nonisolated static let maximumPayloadSize: Int64 = 1_048_576
    private let cache = NSCache<NSString, NSData>()

    init() {
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1_048_576
    }

    func image(deviceId: String, hash: String?) -> Data? {
        guard let hash, !hash.isEmpty else { return nil }
        return cache.object(forKey: key(deviceId: deviceId, hash: hash)) as Data?
    }

    /// Validate and downsample before retaining any peer-supplied image. The
    /// hash is an opaque protocol cache key, not an authentication mechanism.
    @discardableResult
    func store(_ data: Data, deviceId: String, hash: String?) -> Data? {
        guard !data.isEmpty, data.count <= Self.maximumPayloadSize,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let png = output as Data
        if let hash, !hash.isEmpty {
            cache.setObject(png as NSData, forKey: key(deviceId: deviceId, hash: hash), cost: png.count)
        }
        return png
    }

    func removeAll() { cache.removeAllObjects() }

    /// Android's status-bar icon: one flat colour on transparency. The phone
    /// sends it when a notification has no picture of its own (Tailscale,
    /// Truecaller), and it needs drawing as a tinted symbol, not a photo.
    nonisolated static func isGlyph(_ png: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }

        let totalPixels = side * side
        var transparentCount = 0
        var measuredCount = 0
        var sumR = 0
        var sumG = 0
        var sumB = 0
        var totalWeight = 0

        struct ColorPixel { let r: Int; let g: Int; let b: Int }
        var measured: [ColorPixel] = []
        measured.reserveCapacity(totalPixels)

        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[pixel + 3])
            if alpha < 16 {
                transparentCount += 1
            } else if alpha >= 48 {
                let r = min(255, (Int(pixels[pixel]) * 255 + alpha / 2) / alpha)
                let g = min(255, (Int(pixels[pixel + 1]) * 255 + alpha / 2) / alpha)
                let b = min(255, (Int(pixels[pixel + 2]) * 255 + alpha / 2) / alpha)
                measured.append(ColorPixel(r: r, g: g, b: b))
                sumR += r * alpha
                sumG += g * alpha
                sumB += b * alpha
                totalWeight += alpha
                measuredCount += 1
            }
        }

        // Must have some visible content (at least 0.5% ink)
        guard measuredCount >= totalPixels / 200, totalWeight > 0 else { return false }

        let meanR = sumR / totalWeight
        let meanG = sumG / totalWeight
        let meanB = sumB / totalWeight

        var maxDevR = 0
        var maxDevG = 0
        var maxDevB = 0
        for p in measured {
            maxDevR = max(maxDevR, abs(p.r - meanR))
            maxDevG = max(maxDevG, abs(p.g - meanG))
            maxDevB = max(maxDevB, abs(p.b - meanB))
        }
        let maxDeviation = max(maxDevR, max(maxDevG, maxDevB))

        let transparentRatio = Double(transparentCount) / Double(totalPixels)
        let isUniform = maxDeviation <= 24
        let isNearWhite = meanR >= 210 && meanG >= 210 && meanB >= 210 &&
                          (max(meanR, max(meanG, meanB)) - min(meanR, min(meanG, meanB)) <= 15)

        return isUniform && (transparentRatio >= 0.25 || (isNearWhite && transparentRatio >= 0.10))
    }

    private func key(deviceId: String, hash: String) -> NSString {
        // Length-prefix the device ID so peer-controlled components cannot collide.
        "\(deviceId.utf8.count):\(deviceId)\(hash)" as NSString
    }

    /// UserNotifications may move the source file into its own store. Give it
    /// a fresh, disposable copy every time; never hand it a cache file.
    struct PreparedAttachment {
        let attachment: UNNotificationAttachment
        let sourceURL: URL

        nonisolated func removeSource() { try? FileManager.default.removeItem(at: sourceURL) }
    }

    static func attachment(_ png: Data) -> PreparedAttachment? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmate-notification-\(UUID().uuidString).png")
        do {
            try png.write(to: file, options: [.atomic, .completeFileProtection])
            let attachment = try UNNotificationAttachment(identifier: "android-notification-image", url: file, options: [
                UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier,
                UNNotificationAttachmentOptionsThumbnailHiddenKey: false
            ])
            return PreparedAttachment(attachment: attachment, sourceURL: file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }
}

/// Only the current revision may finish a deferred alert. Late payloads can
/// update the list, but must never re-alert or resurrect a dismissed item.
struct NotificationImageTracker {
    struct Key: Hashable {
        let deviceId: String
        let notificationId: String
    }
    private struct Revision {
        let packetId: Int64
        let token: UUID
        let hash: String?
        var waiting: Bool
    }
    private var revisions: [Key: Revision] = [:]

    mutating func begin(_ key: Key, packetId: Int64, hash: String? = nil, waiting: Bool) -> UUID {
        let token = UUID()
        revisions[key] = Revision(packetId: packetId, token: token, hash: hash, waiting: waiting)
        return token
    }

    func token(for key: Key, packetId: Int64, hash: String? = nil) -> UUID? {
        guard let revision = revisions[key] else { return nil }
        // Android may send a hash-only update while the identical artwork is
        // still downloading for an earlier revision of this notification.
        guard revision.packetId == packetId || (hash?.isEmpty == false && revision.hash == hash) else { return nil }
        return revision.token
    }

    func currentToken(for key: Key) -> UUID? { revisions[key]?.token }

    mutating func takeWaiting(_ key: Key, token: UUID) -> Bool {
        guard let revision = revisions[key], revision.token == token, revision.waiting else { return false }
        revisions[key]?.waiting = false
        return true
    }

    mutating func remove(_ key: Key) { revisions.removeValue(forKey: key) }
    mutating func removeDevice(_ deviceId: String) {
        revisions = revisions.filter { $0.key.deviceId != deviceId }
    }
}
