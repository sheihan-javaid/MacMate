//
//  WallpaperSyncTests.swift
//  MacMateTests
//

import AppKit
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MacMate

struct WallpaperSyncTests {
    private func pngData(side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    // MARK: - Hash computation

    @Test func sha256MatchesCryptoKitOverExactBytes() throws {
        let data = try #require(pngData(side: 64))
        let result = try #require(WallpaperPreparer.prepare(data, sourceURL: tempURL("wp_hash.png")))
        let expected = Array(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
        #expect(result.sha256 == expected)
        #expect(result.mimeType == "image/png")
        #expect(result.width == 64 && result.height == 64)
        #expect(result.data == data)
    }

    // MARK: - Skip-if-unchanged (dedupe) and throttling (gatekeeper)

    @Test func gatekeeperDedupeByHash() {
        let gk = WallpaperSendGatekeeper(minSendInterval: 0)
        let now = Date()
        #expect(gk.canSend(deviceId: "dev1", hash: "aaa", now: now) == true)
        gk.recordSuccess(deviceId: "dev1", hash: "aaa", now: now)
        #expect(gk.canSend(deviceId: "dev1", hash: "aaa", now: now) == false) // unchanged -> skip
        #expect(gk.canSend(deviceId: "dev1", hash: "bbb", now: now) == true) // changed -> send
    }

    @Test func canAttemptHonoursMinimumInterval() {
        let gk = WallpaperSendGatekeeper(minSendInterval: 60)
        let now = Date()
        #expect(gk.canAttempt(deviceId: "dev1", now: now) == true)             // never tried
        gk.recordAttempt(deviceId: "dev1", now: now)
        #expect(gk.canAttempt(deviceId: "dev1", now: now.addingTimeInterval(30)) == false)
        #expect(gk.canAttempt(deviceId: "dev1", now: now.addingTimeInterval(61)) == true)
        #expect(gk.canAttempt(deviceId: "dev2", now: now) == true)             // per device
    }

    @Test func gatekeeperDedupeClearedOnReconnect() {
        let gk = WallpaperSendGatekeeper(minSendInterval: 0)
        let now = Date()
        gk.recordSuccess(deviceId: "dev1", hash: "aaa", now: now)
        #expect(gk.canSend(deviceId: "dev1", hash: "aaa", now: now) == false) // deduped
        gk.reset(deviceId: "dev1") // (re)connect clears dedupe
        #expect(gk.canSend(deviceId: "dev1", hash: "aaa", now: now) == true) // re-offered
    }

    @Test func gatekeeperFailureDoesNotRecordSuccess() {
        // A timed-out / declined upload must not mark the hash as sent, so a
        // later changed wallpaper can still be offered (subject to throttle).
        let gk = WallpaperSendGatekeeper(minSendInterval: 0)
        let now = Date()
        #expect(gk.canSend(deviceId: "dev1", hash: "aaa", now: now) == true)
        // No recordSuccess call -> hash not remembered.
        #expect(gk.canSend(deviceId: "dev1", hash: "bbb", now: now) == true)
    }

    @Test func gatekeeperThrottlesByMinimumInterval() {
        let gk = WallpaperSendGatekeeper(minSendInterval: 100)
        let t0 = Date()
        #expect(gk.canSend(deviceId: "dev1", hash: "aaa", now: t0) == true)
        gk.recordSuccess(deviceId: "dev1", hash: "aaa", now: t0)
        // Different hash, but within the minimum interval -> throttled.
        #expect(gk.canSend(deviceId: "dev1", hash: "bbb", now: t0.addingTimeInterval(5)) == false)
        // Past the interval -> allowed.
        #expect(gk.canSend(deviceId: "dev1", hash: "bbb", now: t0.addingTimeInterval(200)) == true)
    }

    @Test func gatekeeperIsIndependentPerDevice() {
        let gk = WallpaperSendGatekeeper(minSendInterval: 0)
        let now = Date()
        #expect(gk.canSend(deviceId: "dev1", hash: "aaa", now: now) == true)
        gk.recordSuccess(deviceId: "dev1", hash: "aaa", now: now)
        #expect(gk.canSend(deviceId: "dev1", hash: "aaa", now: now) == false)
        // A different device is unaffected.
        #expect(gk.canSend(deviceId: "dev2", hash: "aaa", now: now) == true)
    }

    // MARK: - Size / dimension caps

    @Test func smallImageKeptAsIsWithinCaps() throws {
        let data = try #require(pngData(side: 100))
        let result = try #require(WallpaperPreparer.prepare(data, sourceURL: tempURL("wp_small.png")))
        #expect(result.data == data)
        #expect(result.mimeType == "image/png")
        #expect(result.width == 100 && result.height == 100)
        #expect(result.data.count <= WallpaperPreparer.maxTransferBytes)
        #expect(result.width <= WallpaperPreparer.maxImageSide && result.height <= WallpaperPreparer.maxImageSide)
        #expect(result.width * result.height <= WallpaperPreparer.maxTotalPixels)
    }

    @Test func largeImageDownscaledToHardCaps() throws {
        let data = try #require(pngData(side: 5000))
        let result = try #require(WallpaperPreparer.prepare(data, sourceURL: tempURL("wp_large.png")))
        #expect(result.width <= WallpaperPreparer.maxImageSide)
        #expect(result.height <= WallpaperPreparer.maxImageSide)
        #expect(result.width * result.height <= WallpaperPreparer.maxTotalPixels)
        #expect(result.data.count <= WallpaperPreparer.maxTransferBytes)
        // The 5000 px source must be downscaled toward the ~1600-1920 target.
        #expect(result.width <= WallpaperPreparer.targetMaxSide && result.height <= WallpaperPreparer.targetMaxSide)
        #expect(result.mimeType == "image/jpeg")
    }

    @Test func veryLargeImageNeverExceedsByteCap() throws {
        let data = try #require(pngData(side: 8000))
        guard let result = WallpaperPreparer.prepare(data, sourceURL: tempURL("wp_huge.png")) else {
            Issue.record("Expected a downscaled result even for an 8000 px source")
            return
        }
        #expect(result.data.count <= WallpaperPreparer.maxTransferBytes)
        #expect(result.width <= WallpaperPreparer.maxImageSide)
        #expect(result.height <= WallpaperPreparer.maxImageSide)
    }

    @Test func nonImageDataIsRejected() {
        #expect(WallpaperPreparer.prepare(Data("not an image".utf8), sourceURL: tempURL("wp_bad.png")) == nil)
    }
}
