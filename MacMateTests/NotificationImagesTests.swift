import AppKit
import ImageIO
import Testing
@testable import MacMate

@MainActor
struct NotificationImagesTests {
    private func png(width: Int = 32, height: Int = 32) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    /// A test image drawn by `draw`, on transparency.
    private func drawnPNG(width: Int = 32, height: Int = 32, _ draw: (CGContext) -> Void) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        draw(context.cgContext)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func recognisesStatusBarGlyphsButNotPhotos() throws {
        // Tailscale-style: a white shape on transparency.
        let glyph = try drawnPNG { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        #expect(NotificationImages.isGlyph(glyph))

        // A round avatar with an initial: transparent corners, two colours.
        let avatar = try drawnPNG { context in
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            context.fillEllipse(in: CGRect(x: 0, y: 0, width: 32, height: 32))
            context.setFillColor(.white)
            context.fill(CGRect(x: 12, y: 8, width: 8, height: 16))
        }
        #expect(!NotificationImages.isGlyph(avatar))

        // A square photo: no transparency at all.
        let photo = try drawnPNG { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        #expect(!NotificationImages.isGlyph(photo))
    }

    @Test func recognisesComplexGlyphsAndProtectsPhotos() throws {
        // 1. White "in"-style glyph with antialiased edges (LinkedIn case)
        let linkedInGlyph = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            let text = "in" as NSString
            let font = NSFont.boldSystemFont(ofSize: 52)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height), withAttributes: attrs)
            return true
        }
        let linkedInPNG = try #require(linkedInGlyph.tiffRepresentation)
        let linkedInRep = try #require(NSBitmapImageRep(data: linkedInPNG))
        let linkedInData = try #require(linkedInRep.representation(using: .png, properties: [:]))
        #expect(NotificationImages.isGlyph(linkedInData))

        // 2. Solid single-color glyph (monochrome silhouette)
        let solidGlyph = try drawnPNG(width: 64, height: 64) { context in
            context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1.0))
            context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
        }
        #expect(NotificationImages.isGlyph(solidGlyph))

        // 3. Near-white knocked-out badge (white rounded rect with cutout)
        let knockedOutBadge = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            let badge = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56), xRadius: 12, yRadius: 12)
            NSColor.white.setFill()
            badge.fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            let text = "in" as NSString
            let font = NSFont.boldSystemFont(ofSize: 34)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let size = text.size(withAttributes: attrs)
            text.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height), withAttributes: attrs)
            return true
        }
        let badgePNG = try #require(knockedOutBadge.tiffRepresentation)
        let badgeRep = try #require(NSBitmapImageRep(data: badgePNG))
        let badgeData = try #require(badgeRep.representation(using: .png, properties: [:]))
        #expect(NotificationImages.isGlyph(badgeData))

        // 4. Circular avatar photo with transparent corners
        let circularAvatar = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            let circle = NSBezierPath(ovalIn: rect)
            circle.addClip()
            let gradient = NSGradient(colors: [NSColor.systemBlue, NSColor.systemOrange, NSColor.systemPurple])!
            gradient.draw(in: rect, angle: 45)
            return true
        }
        let avatarPNG = try #require(circularAvatar.tiffRepresentation)
        let avatarRep = try #require(NSBitmapImageRep(data: avatarPNG))
        let avatarData = try #require(avatarRep.representation(using: .png, properties: [:]))
        #expect(!NotificationImages.isGlyph(avatarData))

        // 5. Multi-colored logo (e.g. blue square with white letter)
        let multiColorLogo = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            NSColor.systemBlue.setFill()
            NSRect(x: 8, y: 8, width: 48, height: 48).fill()
            let text = "W" as NSString
            let font = NSFont.boldSystemFont(ofSize: 32)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height), withAttributes: attrs)
            return true
        }
        let logoPNG = try #require(multiColorLogo.tiffRepresentation)
        let logoRep = try #require(NSBitmapImageRep(data: logoPNG))
        let logoData = try #require(logoRep.representation(using: .png, properties: [:]))
        #expect(!NotificationImages.isGlyph(logoData))

        // 6. Fully opaque photo
        let opaquePhoto = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let gradient = NSGradient(colors: [NSColor.systemRed, NSColor.systemYellow])!
            gradient.draw(in: rect, angle: 90)
            return true
        }
        let photoPNG = try #require(opaquePhoto.tiffRepresentation)
        let photoRep = try #require(NSBitmapImageRep(data: photoPNG))
        let photoData = try #require(photoRep.representation(using: .png, properties: [:]))
        #expect(!NotificationImages.isGlyph(photoData))
    }

    @Test func cachesOnlyByDeviceAndExplicitImageHash() throws {
        let images = NotificationImages()
        let data = try png()
        let stored = try #require(images.store(data, deviceId: "phone-a", hash: "avatar-1"))
        #expect(images.image(deviceId: "phone-a", hash: "avatar-1") == stored)
        #expect(images.image(deviceId: "phone-b", hash: "avatar-1") == nil)
        #expect(images.image(deviceId: "phone-a", hash: "avatar-2") == nil)
        #expect(images.image(deviceId: "phone-a", hash: nil) == nil)
        #expect(images.store(data, deviceId: "phone-a", hash: nil) != nil)
        images.removeAll()
        #expect(images.image(deviceId: "phone-a", hash: "avatar-1") == nil)
    }

    @Test func rejectsCorruptAndOversizedImagesAndDownsamplesValidPNGs() throws {
        let images = NotificationImages()
        #expect(images.store(Data("not an image".utf8), deviceId: "p", hash: "bad") == nil)
        #expect(images.store(Data(count: Int(NotificationImages.maximumPayloadSize) + 1), deviceId: "p", hash: "big") == nil)
        #expect(images.image(deviceId: "p", hash: "bad") == nil)
        let data = try #require(images.store(png(width: 512, height: 256), deviceId: "p", hash: "wide"))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 128)
        #expect(image.height == 64)
    }

    @Test func keepsAttachmentSourceUntilSchedulingCompletes() throws {
        let data = try png()
        let first = try #require(NotificationImages.attachment(data))
        let second = try #require(NotificationImages.attachment(data))
        defer { first.removeSource(); second.removeSource() }
        #expect(first.sourceURL != second.sourceURL)
        #expect(FileManager.default.fileExists(atPath: first.sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: second.sourceURL.path))
        first.removeSource()
        #expect(!FileManager.default.fileExists(atPath: first.sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: second.sourceURL.path))
    }

    @Test func delayedPayloadAndTimeoutCanDeliverOnlyOnce() {
        var tracker = NotificationImageTracker()
        let key = NotificationImageTracker.Key(deviceId: "p", notificationId: "chat")
        let token = tracker.begin(key, packetId: 1, waiting: true)
        let delivery1 = tracker.takeWaiting(key, token: token)
        #expect(delivery1)
        let delivery2 = !tracker.takeWaiting(key, token: token)
        #expect(delivery2)
        #expect(tracker.token(for: key, packetId: 1) == token) // list may still update
    }

    @Test func updateCancelDisconnectAndSilentSyncInvalidateDeferredAlerts() {
        var tracker = NotificationImageTracker()
        let key = NotificationImageTracker.Key(deviceId: "p", notificationId: "chat")
        let old = tracker.begin(key, packetId: 1, waiting: true)
        let silent = tracker.begin(key, packetId: 2, waiting: false)
        let delivery3 = !tracker.takeWaiting(key, token: old)
        #expect(delivery3)
        let delivery4 = !tracker.takeWaiting(key, token: silent)
        #expect(delivery4)
        #expect(tracker.token(for: key, packetId: 1) == nil)
        let cancelled = tracker.begin(key, packetId: 3, waiting: true)
        tracker.remove(key)
        let delivery5 = !tracker.takeWaiting(key, token: cancelled)
        #expect(delivery5)
        let disconnected = tracker.begin(key, packetId: 4, waiting: true)
        tracker.removeDevice("p")
        let delivery6 = !tracker.takeWaiting(key, token: disconnected)
        #expect(delivery6)
        #expect(tracker.token(for: key, packetId: 4) == nil)
    }

    @Test func acceptsAnEarlierPayloadOnlyWhenItsHashMatchesTheCurrentArtwork() {
        var tracker = NotificationImageTracker()
        let key = NotificationImageTracker.Key(deviceId: "p", notificationId: "chat")
        _ = tracker.begin(key, packetId: 1, hash: "avatar-a", waiting: true)
        let current = tracker.begin(key, packetId: 2, hash: "avatar-a", waiting: false)
        #expect(tracker.token(for: key, packetId: 1, hash: "avatar-a") == current)
        #expect(tracker.token(for: key, packetId: 1, hash: "avatar-b") == nil)
        _ = tracker.begin(key, packetId: 3, hash: "avatar-b", waiting: true)
        #expect(tracker.token(for: key, packetId: 1, hash: "avatar-a") == nil)
    }

    @Test func devicesWithTheSameAndroidIdStayIndependent() {
        var tracker = NotificationImageTracker()
        let a = NotificationImageTracker.Key(deviceId: "a", notificationId: "chat")
        let b = NotificationImageTracker.Key(deviceId: "b", notificationId: "chat")
        let first = tracker.begin(a, packetId: 1, waiting: true)
        let second = tracker.begin(b, packetId: 1, waiting: true)
        tracker.removeDevice("a")
        let delivery7 = !tracker.takeWaiting(a, token: first)
        #expect(delivery7)
        let delivery8 = tracker.takeWaiting(b, token: second)
        #expect(delivery8)
        #expect(NotificationPlugin.identifier(deviceId: "a", id: "chat") != NotificationPlugin.identifier(deviceId: "b", id: "chat"))
        #expect(NotificationPlugin.identifier(deviceId: "a", id: "bc") != NotificationPlugin.identifier(deviceId: "ab", id: "c"))
    }

    @Test func waitsOnlyForUsableImageAnnouncements() {
        func packet(_ size: Int64?, _ port: Any?) -> NetworkPacket {
            NetworkPacket(type: "kdeconnect.notification", payloadSize: size,
                          payloadTransferInfo: port.map { ["port": $0] })
        }
        #expect(NotificationPlugin.expectsImage(packet(100, 1739)))
        #expect(NotificationPlugin.expectsImage(packet(100, "1739")))
        #expect(!NotificationPlugin.expectsImage(packet(nil, 1739)))
        #expect(!NotificationPlugin.expectsImage(packet(0, 1739)))
        #expect(!NotificationPlugin.expectsImage(packet(NotificationImages.maximumPayloadSize + 1, 1739)))
        #expect(!NotificationPlugin.expectsImage(packet(100, nil)))
        #expect(!NotificationPlugin.expectsImage(packet(100, 65536)))
        #expect(!NotificationPlugin.expectsImage(packet(100, "bad")))
    }

    @Test func tileOutputIsValid256x256PNG() throws {
        let resolver = AppIconResolver()
        let whatsappData = resolver.tile(forPackage: "com.whatsapp", appName: "WhatsApp")
        #expect(!whatsappData.isEmpty)
        let waSource = try #require(CGImageSourceCreateWithData(whatsappData as CFData, nil))
        let waImage = try #require(CGImageSourceCreateImageAtIndex(waSource, 0, nil))
        #expect(waImage.width == 256)
        #expect(waImage.height == 256)

        // Monogram fallback
        let fallbackData = resolver.tile(forPackage: "com.unknown.bank", appName: "Bank")
        #expect(!fallbackData.isEmpty)
        let fbSource = try #require(CGImageSourceCreateWithData(fallbackData as CFData, nil))
        let fbImage = try #require(CGImageSourceCreateImageAtIndex(fbSource, 0, nil))
        #expect(fbImage.width == 256)
        #expect(fbImage.height == 256)
    }

    @Test func samePackageAlwaysGivesSameMonogramColor() {
        let resolver = AppIconResolver()
        let data1 = resolver.tile(forPackage: "com.custom.app", appName: "Custom")
        let data2 = resolver.tile(forPackage: "com.custom.app", appName: "Custom")
        #expect(data1 == data2)

        let hash1 = AppIconResolver.fnv1a64("com.custom.app")
        let hash2 = AppIconResolver.fnv1a64("com.custom.app")
        #expect(hash1 == hash2)
    }

    @Test func unknownPackagesFallBackSafely() throws {
        let resolver = AppIconResolver()
        let notesData = resolver.tile(forPackage: nil, appName: "Notes")
        let notesSource = try #require(CGImageSourceCreateWithData(notesData as CFData, nil))
        let notesImage = try #require(CGImageSourceCreateImageAtIndex(notesSource, 0, nil))
        #expect(notesImage.width == 256)

        let internalData = resolver.tile(forPackage: "custom.internal.tool", appName: "")
        let internalSource = try #require(CGImageSourceCreateWithData(internalData as CFData, nil))
        let internalImage = try #require(CGImageSourceCreateImageAtIndex(internalSource, 0, nil))
        #expect(internalImage.width == 256)

        let emptyData = resolver.tile(forPackage: nil, appName: "")
        let emptySource = try #require(CGImageSourceCreateWithData(emptyData as CFData, nil))
        let emptyImage = try #require(CGImageSourceCreateImageAtIndex(emptySource, 0, nil))
        #expect(emptyImage.width == 256)
    }

    @Test func photosAreNeverReplacedAndTilesAttachForGlyphsOrMissing() throws {
        let photoData = try png(width: 64, height: 64)
        let photoNotif = PhoneNotification(
            id: "0|com.whatsapp|1|null|1000",
            deviceId: "dev_1",
            appName: "WhatsApp",
            title: "Alex",
            text: "Hello",
            date: Date(),
            replyId: nil,
            isDismissable: true,
            imageData: photoData
        )
        // A photo (non-glyph) must retain its original photo data
        #expect(!photoNotif.imageIsGlyph)
        #expect(photoNotif.imageData == photoData)

        // When image is a glyph, AppIconResolver supplies the tile
        let glyphPNG = try drawnPNG { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        let glyphNotif = PhoneNotification(
            id: "0|com.linkedin.android|2|null|1001",
            deviceId: "dev_1",
            appName: "LinkedIn",
            title: "Notice",
            text: "Job alert",
            date: Date(),
            replyId: nil,
            isDismissable: true,
            imageData: glyphPNG
        )
        #expect(glyphNotif.imageIsGlyph)

        let linkedInTile = AppIconResolver.shared.tile(forPackage: "com.linkedin.android", appName: "LinkedIn")
        #expect(linkedInTile != glyphPNG)
        #expect(!linkedInTile.isEmpty)
    }

    @Test func attachmentLifecycleAndTempFileCleanupWorkForTiles() throws {
        let tileData = AppIconResolver.shared.tile(forPackage: "com.whatsapp", appName: "WhatsApp")
        let prepared = try #require(NotificationImages.attachment(tileData))
        let path = prepared.sourceURL.path
        #expect(FileManager.default.fileExists(atPath: path))
        prepared.removeSource()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
