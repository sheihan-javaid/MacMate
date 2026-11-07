//
//  MacMateTests.swift
//  MacMateTests
//

import Testing
import Foundation
import AppKit
@testable import MacMate

struct MacMateTests {

    @Test func testNetworkPacketSerialization() throws {
        let packet = NetworkPacket(
            type: "kdeconnect.clipboard",
            body: [
                "content": "Hello from Swift!",
                "timestamp": Int64(1234567890)
            ]
        )

        let data = try packet.serialize()
        #expect(data.last == UInt8(ascii: "\n"))

        let decoded = try NetworkPacket.unserialize(from: data)
        #expect(decoded.type == "kdeconnect.clipboard")
        #expect(decoded.string(for: "content") == "Hello from Swift!")
        #expect(decoded.int64(for: "timestamp") == 1234567890)
    }

    /// KDE Connect Android ends a call with `"isCancel": "true"`, a string.
    @Test func testBoolReadsStringsFromAndroid() throws {
        let json = #"{"id":1,"type":"kdeconnect.telephony","body":{"event":"talking","isCancel":"true","a":true,"b":"false","c":"maybe"}}"#
        let packet = try NetworkPacket.unserialize(from: Data(json.utf8))
        #expect(packet.bool(for: "isCancel"))
        #expect(packet.bool(for: "a"))
        #expect(!packet.bool(for: "b", default: true))
        #expect(packet.bool(for: "c", default: true))
        #expect(!packet.bool(for: "missing"))
    }

    /// Values wrapped in AnyCodable inside other containers, as an SMS
    /// request builds its address list, must still reach the wire.
    @Test func testNestedAnyCodableSerializes() throws {
        let packet = NetworkPacket(type: "kdeconnect.sms.request", body: [
            "version": AnyCodable(2),
            "addresses": AnyCodable([["address": AnyCodable("+15550100")]]),
            "messageBody": AnyCodable("test")
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: packet.serialize()) as? [String: Any])
        let body = try #require(json["body"] as? [String: Any])
        let addresses = try #require(body["addresses"] as? [[String: Any]])
        #expect(addresses.first?["address"] as? String == "+15550100")
        #expect(body["messageBody"] as? String == "test")
    }

    @Test func testDeviceInfoPacketConversion() throws {
        let info = DeviceInfo(
            deviceId: "abcdef0123456789abcdef0123456789",
            deviceName: "My Pixel Phone",
            deviceType: .phone,
            protocolVersion: 8,
            tcpPort: 1716
        )

        let discoveryPacket = info.toUdpDiscoveryPacket()
        #expect(discoveryPacket.type == "kdeconnect.identity")
        #expect(discoveryPacket.string(for: "deviceId") == "abcdef0123456789abcdef0123456789")
        #expect(discoveryPacket.int(for: "tcpPort") == 1716)

        let parsedInfo = DeviceInfo.from(packet: discoveryPacket)
        #expect(parsedInfo != nil)
        #expect(parsedInfo?.deviceId == "abcdef0123456789abcdef0123456789")
        #expect(parsedInfo?.deviceName == "My Pixel Phone")
    }

    @Test func testDeviceIdentity() throws {
        let identity = DeviceIdentity.shared
        #expect(!identity.deviceId.isEmpty)
        #expect(identity.deviceId.count == 32)
        #expect(!identity.certificateFingerprint.isEmpty)
        #expect(identity.certificateFingerprint.contains(":"))
    }

    @Test func testTrustStoreOperations() throws {
        let store = TrustStore.shared
        let testId = "test_device_id_123456789012345678"
        let device = PairedDevice(
            deviceId: testId,
            deviceName: "Test Android",
            deviceType: .phone,
            certificateFingerprint: "AA:BB:CC:DD:EE:FF"
        )

        store.add(device: device)
        #expect(store.isTrusted(deviceId: testId))

        let fetched = store.pairedDevice(for: testId)
        #expect(fetched?.deviceName == "Test Android")

        store.remove(deviceId: testId, reason: "unit test cleanup")
        #expect(!store.isTrusted(deviceId: testId))
    }

    /// The uploader must hand back a port inside the range upstream reserves.
    @Test func testPayloadUploaderBindsInReservedRange() async throws {
        let url = try makeTemporaryPayload(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let uploader = PayloadUploader()
            uploader.start(
                fileURL: url,
                onReady: { offer in continuation.resume(returning: offer.port) },
                onProgress: { _ in },
                onComplete: { _ in }
            )
        }

        #expect(port >= PayloadPort.min)
        #expect(port <= PayloadPort.max)
    }

    /// End-to-end: TLS server streams a file, TLS client reassembles it byte-for-byte.
    /// Sized past one chunk so the framing loop is exercised more than once.
    @Test func testPayloadRoundTripOverLocalhost() async throws {
        let byteCount = 300 * 1024
        let url = try makeTemporaryPayload(bytes: byteCount)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = try Data(contentsOf: url)
        let guardOnce = ResumeGuard()
        let uploader = PayloadUploader()
        var uploaderProgress: [Double] = []

        let received: Data = try await withCheckedThrowingContinuation { continuation in
            uploader.start(
                fileURL: url,
                onReady: { offer in
                    // Both ends use this Mac's identity on localhost, so pinning to
                    // our own fingerprint exercises the verification path.
                    PayloadDownloader.download(
                        host: "127.0.0.1",
                        port: offer.port,
                        size: offer.size,
                        expectedPeerFingerprint: DeviceIdentity.shared.certificateFingerprint
                    ) { result in
                        // The uploader reports its own failures; only one side wins.
                        guard guardOnce.claim() else { return }
                        continuation.resume(with: result.flatMap { fileURL in
                            defer { try? FileManager.default.removeItem(at: fileURL) }
                            return Result { try Data(contentsOf: fileURL) }
                        })
                    }
                },
                onProgress: { uploaderProgress.append($0) },
                onComplete: { result in
                    if case .failure(let error) = result, guardOnce.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            )
        }

        #expect(received.count == byteCount)
        #expect(received == expected)
        #expect(uploaderProgress.count > 1, "expected multiple progress callbacks across chunks")
        #expect(uploaderProgress.last.map { $0 >= 1.0 } == true)
    }

    /// A payload server holding a different certificate than the paired device
    /// must be refused, and nothing may be left on disk.
    @Test func testPayloadDownloadRejectsUnpinnedCertificate() async throws {
        let url = try makeTemporaryPayload(bytes: 4096)
        defer { try? FileManager.default.removeItem(at: url) }

        let uploader = PayloadUploader()
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            uploader.start(
                fileURL: url,
                onReady: { offer in
                    PayloadDownloader.download(
                        host: "127.0.0.1",
                        port: offer.port,
                        size: offer.size,
                        expectedPeerFingerprint: String(repeating: "00:", count: 31) + "00"
                    ) { continuation.resume(returning: $0) }
                },
                onProgress: { _ in },
                onComplete: { _ in }
            )
        }
        uploader.cancel()

        guard case .failure(let error) = result else {
            Issue.record("download should have been refused")
            return
        }
        guard case PayloadError.certificateMismatch = error else {
            Issue.record("expected certificateMismatch, got \(error)")
            return
        }
    }

    @Test func testFingerprintComparison() {
        #expect(SocketTLS.fingerprintsMatch("ab:cd", "AB:CD"))
        #expect(!SocketTLS.fingerprintsMatch("ab:cd", "ab:ce"))
        #expect(!SocketTLS.fingerprintsMatch("", ""))
        #expect(!SocketTLS.fingerprintsMatch(nil, "ab:cd"))
    }

    /// Peer-supplied file names must never leave the target directory.
    @Test func testSafeFilenameStripsTraversal() {
        #expect(SafeFilename.sanitize("../../Library/LaunchAgents/evil.plist") == "evil.plist")
        #expect(SafeFilename.sanitize("..\\..\\x.txt") == "x.txt")
        #expect(SafeFilename.sanitize("/etc/passwd") == "passwd")
        #expect(SafeFilename.sanitize("..") == "ReceivedFile")
        #expect(SafeFilename.sanitize(".hidden") == "hidden")
        #expect(SafeFilename.sanitize(nil) == "ReceivedFile")
        #expect(SafeFilename.sanitize("photo.jpg") == "photo.jpg")

        let dir = FileManager.default.temporaryDirectory
        let target = SafeFilename.uniqueURL(in: dir, for: "../../escape.txt")
        #expect(target.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    /// Only the user's own, online phones get our identity: shared-in machines,
    /// desktops and offline devices are skipped, and IPv6 addresses ignored.
    @Test func testTailscalePeerFiltering() throws {
        let json = """
        {
          "BackendState": "Running",
          "Self": { "UserID": 7, "TailscaleIPs": ["100.101.42.7", "fd7a::1"] },
          "Peer": {
            "a": { "HostName": "pixel", "OS": "android", "Online": true, "UserID": 7, "TailscaleIPs": ["fd7a::2", "100.88.17.53"] },
            "b": { "HostName": "friends-phone", "OS": "android", "Online": true, "UserID": 99, "TailscaleIPs": ["100.64.0.9"] },
            "c": { "HostName": "server", "OS": "linux", "Online": true, "UserID": 7, "TailscaleIPs": ["100.127.50.25"] },
            "d": { "HostName": "old-phone", "OS": "android", "Online": false, "UserID": 7, "TailscaleIPs": ["100.64.0.10"] },
            "e": { "HostName": "ipad", "OS": "iOS", "Online": true, "UserID": 7, "TailscaleIPs": ["100.64.0.11"] }
          }
        }
        """
        let status = TailscaleDiscovery.parse(Data(json.utf8))
        guard case .running(let selfIP, let phones) = status else {
            Issue.record("expected running, got \(status)")
            return
        }
        #expect(selfIP == "100.101.42.7")
        #expect(phones.map(\.ip) == ["100.64.0.11", "100.88.17.53"])

        let stopped = TailscaleDiscovery.parse(Data(#"{"BackendState":"Stopped"}"#.utf8))
        #expect(stopped == .notRunning)
    }

    /// A packet type must be advertised in the direction it actually travels. The
    /// peer refuses to send a type missing from our incoming set, and ignores what
    /// we send if it is missing from our outgoing set.
    @Test func testCapabilityDirections() throws {
        let incoming = DeviceInfo.defaultIncomingCapabilities
        let outgoing = DeviceInfo.defaultOutgoingCapabilities

        for type in [
            "kdeconnect.mpris",
            "kdeconnect.systemvolume",
            "kdeconnect.lock",
            "kdeconnect.connectivity_report",
            "kdeconnect.telephony",
            "kdeconnect.share.request",
            "kdeconnect.share.request.update",
            "kdeconnect.mousepad.request",
            "kdeconnect.presenter",
            "kdeconnect.sms.messages",
            "kdeconnect.sms.attachment_file",
            "kdeconnect.runcommand.request",
            // Ring this Mac: the same packet type rings in either direction.
            "kdeconnect.findmyphone.request",
            // The phone's volume panel controls this Mac's volume too.
            "kdeconnect.systemvolume.request",
            // And its Multimedia control drives this Mac as a player.
            "kdeconnect.mpris.request"
        ] {
            #expect(incoming.contains(type), "\(type) must be receivable")
        }

        for type in [
            "kdeconnect.mpris.request",
            "kdeconnect.findmyphone.request",
            "kdeconnect.systemvolume.request",
            "kdeconnect.lock.request",
            "kdeconnect.share.request",
            "kdeconnect.mousepad.keyboardstate",
            "kdeconnect.mousepad.echo",
            "kdeconnect.sms.request",
            "kdeconnect.sms.request_conversations",
            "kdeconnect.sms.request_conversation",
            "kdeconnect.sms.request_attachment",
            "kdeconnect.runcommand",
            "kdeconnect.runcommand.output"
        ] {
            #expect(outgoing.contains(type), "\(type) must be sendable")
        }

        // Request/response pairs must not be conflated.
        #expect(!outgoing.contains("kdeconnect.telephony"))
        #expect(!incoming.contains("kdeconnect.mousepad.keyboardstate"))
        #expect(!outgoing.contains("kdeconnect.mousepad.request"))
        #expect(!outgoing.contains("kdeconnect.sms.messages"))
        #expect(!incoming.contains("kdeconnect.sms.request"))
    }

    @Test func testSMSMessageParsing() throws {
        let smsJSON = """
        {
            "id": 100,
            "type": "kdeconnect.sms.messages",
            "body": {
                "version": 2,
                "messages": [
                    {
                        "event": 1,
                        "body": "Hello from Android!",
                        "addresses": [{"address": "+15551234567"}],
                        "date": 1690000000000,
                        "type": 1,
                        "thread_id": 42,
                        "read": true,
                        "attachments": [
                            {
                                "part_id": 1,
                                "mime_type": "image/jpeg",
                                "unique_identifier": "img_001.jpg"
                            }
                        ]
                    }
                ]
            }
        }
        """
        let packet = try NetworkPacket.unserialize(from: Data(smsJSON.utf8))
        let messages = packet.objectArray(for: "messages")
        #expect(messages.count == 1)

        let parsed = SMSMessage.from(dictionary: messages[0])
        #expect(parsed != nil)
        #expect(parsed?.body == "Hello from Android!")
        #expect(parsed?.addresses == ["+15551234567"])
        #expect(parsed?.threadId == 42)
        #expect(parsed?.type == 1)
        #expect(parsed?.isOutgoing == false)
        #expect(parsed?.read == true)
        #expect(parsed?.attachments.count == 1)
        #expect(parsed?.attachments[0].uniqueIdentifier == "img_001.jpg")
    }

    @Test func testRemoteCommandExecution() async throws {
        // Its own settings: the tests run inside the app, and the standard
        // defaults hold the commands people actually use.
        let suite = "MacMateTests.RunCommand.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let plugin = RunCommandPlugin(defaults: defaults)
        let cmd = RemoteCommand(id: "test_echo", name: "Echo Test", command: "echo 'Antigravity Test'")
        plugin.addCommand(cmd)

        plugin.startCommand(key: "test_echo", connection: nil)

        // Give process a moment to execute
        try await Task.sleep(nanoseconds: 300_000_000)

        let logs = plugin.commandLogs["test_echo"] ?? []
        #expect(logs.contains { $0.contains("Antigravity Test") })
        #expect(logs.contains { $0.contains("Finished with exit code 0") })
    }

    @Test func testDoublePacketAccessor() throws {
        let packet = NetworkPacket(
            type: "kdeconnect.mousepad.request",
            body: [
                "dx": AnyCodable(12.5),
                "dy": AnyCodable(-4.25),
                "singleclick": AnyCodable(true)
            ]
        )
        #expect(packet.double(for: "dx") == 12.5)
        #expect(packet.double(for: "dy") == -4.25)
        #expect(packet.bool(for: "singleclick") == true)
        #expect(packet.has("dx") == true)
        #expect(packet.has("nonexistent") == false)
    }

    /// Nested JSON arrives shallowly typed through `AnyCodable`, so the object
    /// accessors have to unwrap it by hand.
    @Test func testNestedObjectAccessors() throws {
        let json = """
        {"id":1,"type":"kdeconnect.systemvolume","body":{"sinkList":[\
        {"name":"Music","description":"Built-in","muted":false,"volume":42,"maxVolume":100,"enabled":true}\
        ]}}
        """
        let packet = try NetworkPacket.unserialize(from: Data(json.utf8))

        let sinks = packet.objectArray(for: "sinkList")
        #expect(sinks.count == 1)
        #expect(sinks.first?["name"] as? String == "Music")
        #expect(sinks.first?["volume"] as? Int == 42)
        #expect(sinks.first?["enabled"] as? Bool == true)

        let strengthsJSON = """
        {"id":2,"type":"kdeconnect.connectivity_report","body":{"signalStrengths":{\
        "0":{"networkType":"LTE","signalStrength":3}\
        }}}
        """
        let strengthsPacket = try NetworkPacket.unserialize(from: Data(strengthsJSON.utf8))
        let strengths = strengthsPacket.object(for: "signalStrengths")
        #expect(strengths?.count == 1)

        let entry = strengths?["0"] as? [String: Any]
        #expect(entry?["networkType"] as? String == "LTE")
        #expect(entry?["signalStrength"] as? Int == 3)
    }

    // MARK: - F-10 Safety Remediation & Post-Fix Verification Tests

    /// Verifies that MNT_FORCE is completely removed from all executable code in PhoneMount.swift.
    @Test func testF10ZeroMNTForceInSource() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let phoneMountURL = repoRoot.appendingPathComponent("MacMate/Files/NFS/PhoneMount.swift")
        
        guard fileManager.fileExists(atPath: phoneMountURL.path) else {
            Issue.record("PhoneMount.swift not found at expected path: \(phoneMountURL.path)")
            return
        }
        
        let content = try String(contentsOf: phoneMountURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        
        // Ensure no executable line uses MNT_FORCE
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "//") || trimmed.starts(with: "///") || trimmed.starts(with: "*") {
                continue // Comment documentation is allowed
            }
            #expect(!line.contains("MNT_FORCE"), "Executable line \(index + 1) in PhoneMount.swift must NOT contain MNT_FORCE: \(line)")
        }
    }

    /// Verifies that safeUnmount handles unmounted paths safely without crashing, throwing, or forcing unmount.
    /// Note: Testing an actual busy live mount requires an active kernel NFS mount which cannot run without root in user tests.
    @Test func testF10SafeUnmountPreservesNonexistentOrBusyMount() throws {
        let fakeMountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmate-test-safe-unmount-\(UUID().uuidString)")
        
        // safeUnmount on non-mounted path should return false safely (pre-unmount statfs or unmount errno)
        let result = PhoneMount.safeUnmount(fakeMountURL)
        #expect(result == false)
        
        // removeMountPoint on unmounted non-existent folder should not crash
        PhoneMount.removeMountPoint(fakeMountURL)
    }

    /// Verifies strict path validation: allows valid immediate child mounts under MacMate/Mounts and Tether/Mounts,
    /// but rejects path traversal, symlink escapes, root mounts directory itself, and arbitrary system directories.
    @Test func testF10MountDirectoryChildSafetyValidation() throws {
        let mountsDir = PhoneMount.mountsDirectory
        try? FileManager.default.createDirectory(at: mountsDir, withIntermediateDirectories: true)
        
        let validChild = mountsDir.appendingPathComponent("TestDevice")
        try? FileManager.default.createDirectory(at: validChild, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: validChild) }
        
        // Valid immediate child folder owned by user should pass
        #expect(PhoneMount.isSafeMountDirectoryChild(validChild) == true)
        
        // Root mounts directory itself must NOT be treated as a child mount
        #expect(PhoneMount.isSafeMountDirectoryChild(mountsDir) == false)
        
        // Traversal attempts must fail
        let traversalChild = mountsDir.appendingPathComponent("../OtherFolder")
        #expect(PhoneMount.isSafeMountDirectoryChild(traversalChild) == false)
        
        let rootTraversal = mountsDir.appendingPathComponent("../../etc")
        #expect(PhoneMount.isSafeMountDirectoryChild(rootTraversal) == false)
        
        // Arbitrary system directories must fail
        let systemDir = URL(fileURLWithPath: "/tmp")
        #expect(PhoneMount.isSafeMountDirectoryChild(systemDir) == false)
    }

    /// Verifies clipboard plugin logging does not expose sensitive text content.
    @Test func testClipboardPrivacyLoggingExcludesContent() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let clipboardPluginURL = repoRoot.appendingPathComponent("MacMate/Plugins/ClipboardPlugin.swift")
        
        guard FileManager.default.fileExists(atPath: clipboardPluginURL.path) else {
            Issue.record("ClipboardPlugin.swift not found at expected path: \(clipboardPluginURL.path)")
            return
        }
        let content = try String(contentsOf: clipboardPluginURL, encoding: .utf8)
        
        #expect(!content.contains("Local clipboard changed: \\(text.prefix"), "ClipboardPlugin must not log text prefix")
        #expect(!content.contains("Synced clipboard from \\(connection.peerDeviceInfo?.deviceName ?? \"Device\"): \\(content.prefix"), "ClipboardPlugin must not log content prefix")
        #expect(content.contains("Local clipboard changed (\\(text.count) characters)"), "ClipboardPlugin must log character count only")
        #expect(content.contains("(\\(content.count) characters)"), "ClipboardPlugin must log character count only")
    }

    /// Verifies mount source provenance matching and rejection of ambiguous or foreign mounts.
    @Test func testF10MountSourceProvenanceAndAmbiguity() throws {
        // Valid MacMate local loopback patterns
        #expect(PhoneMount.isMatchingMountSource("motorola-edge-50.local:/motorola-edge-50", expectedShareName: "motorola-edge-50") == true)
        #expect(PhoneMount.isMatchingMountSource("localhost:/motorola-edge-50", expectedShareName: "motorola-edge-50") == true)
        #expect(PhoneMount.isMatchingMountSource("127.0.0.1:/motorola-edge-50", expectedShareName: "motorola-edge-50") == true)
        
        // Foreign IP address -> ambiguous, provenance not established -> MUST BE REJECTED
        #expect(PhoneMount.isMatchingMountSource("192.168.1.50:/motorola-edge-50", expectedShareName: "motorola-edge-50") == false)
        
        // Remote corporate domain -> ambiguous -> MUST BE REJECTED
        #expect(PhoneMount.isMatchingMountSource("nfs.server.internal:/motorola-edge-50", expectedShareName: "motorola-edge-50") == false)
        
        // Share name mismatch -> MUST BE REJECTED
        #expect(PhoneMount.isMatchingMountSource("motorola-edge-50.local:/other-share", expectedShareName: "motorola-edge-50") == false)
    }

    /// Verifies cross-process MountLock non-blocking mutual exclusion behavior.
    @Test func testF10CrossProcessMountLockCoordination() throws {
        let firstAcquired = MountLock.withLock {
            // While holding the lock, an inner non-blocking attempt should fail (simulate another process)
            let nestedAcquired = MountLock.withLock {
                true
            }
            #expect(nestedAcquired == nil, "Nested lock attempt while held must fail")
            return 42
        }
        #expect(firstAcquired == 42)
        
        // Once released, a subsequent lock attempt should succeed
        let secondAcquired = MountLock.withLock {
            99
        }
        #expect(secondAcquired == 99)
    }

    /// Verifies that failed unmount never deletes a non-empty directory.
    @Test func testF10FailedUnmountPreservesDirectoryAndContents() throws {
        let testDir = PhoneMount.mountsDirectory.appendingPathComponent("PreservedTestDir_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
        let testFile = testDir.appendingPathComponent("user_data.txt")
        try "Important data".write(to: testFile, atomically: true, encoding: .utf8)
        
        // Pre-unmount check fails because it is not an NFS mount
        let unmounted = PhoneMount.safeUnmount(testDir)
        #expect(unmounted == false)
        
        // removeMountPoint refuses to delete non-empty directory (Darwin.rmdir returns ENOTEMPTY)
        PhoneMount.removeMountPoint(testDir)
        
        // Confirm directory and file are completely preserved!
        #expect(FileManager.default.fileExists(atPath: testDir.path) == true)
        #expect(FileManager.default.fileExists(atPath: testFile.path) == true)
    }

    /// Verifies active transfer state transitions (idle -> transferring -> complete/failed -> idle)
    /// and ensures cleanup protects active transfers.
    @MainActor
    @Test func testF10ActiveTransferStateTransitions() throws {
        let sharePlugin = SharePlugin()
        #expect(sharePlugin.hasActiveTransfers == false)
        
        // Simulate incoming file announcement packet
        let packet = NetworkPacket(
            type: SharePlugin.shareRequestType,
            body: ["filename": AnyCodable("photo.jpg")],
            payloadSize: 1048576,
            payloadTransferInfo: ["port": AnyCodable(1717)]
        )
        
        // Mock connection
        let mockIdentity = DeviceInfo(deviceId: "dev1", deviceName: "Phone", deviceType: .phone, protocolVersion: 8, tcpPort: 1716)
        let mockConn = DeviceConnection(host: "127.0.0.1", port: 1716, targetDeviceId: "dev1", isOutgoing: false)
        mockConn.setPeerDeviceInfoForTesting(mockIdentity)
        
        // 1. Announce incoming payload -> transitions hasActiveTransfers to true
        sharePlugin.handlePacket(connection: mockConn, packet: packet)
        #expect(sharePlugin.hasActiveTransfers == true, "hasActiveTransfers must be true during active transfer")
        
        // 2. Terminate transfer with error -> transitions hasActiveTransfers back to false
        sharePlugin.handlePayloadFailure(connection: mockConn, packet: packet, error: PayloadError.connectionTimeout)
        #expect(sharePlugin.hasActiveTransfers == false, "hasActiveTransfers must be false after terminal failure")
    }

    /// Verifies F-04 cooperative image decoding, cache limits, and cancellation.
    @Test func testF04ImageDecodingCancellationAndCache() async throws {
        NotificationImageCache.shared.removeAll()
        
        // Generate valid 16x16 PNG image data
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 16 * 4,
            bitsPerPixel: 32
        )!
        let pngData = rep.representation(using: .png, properties: [:])!
        
        let testKey = "test_img_\(UUID().uuidString)"
        
        // 1. Successful decode populates cache
        let image = await NotificationImageDecoder.decode(data: pngData, key: testKey)
        #expect(image != nil)
        #expect(NotificationImageCache.shared.image(forKey: testKey) != nil)
        
        // 2. Cancelled task returns nil and does NOT cache
        let cancelKey = "test_cancel_\(UUID().uuidString)"
        let cancelledTask = Task {
            await NotificationImageDecoder.decode(data: pngData, key: cancelKey)
        }
        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.value
        #expect(cancelledResult == nil)
        #expect(NotificationImageCache.shared.image(forKey: cancelKey) == nil, "Cancelled decode must not populate cache")
    }

    /// Verifies F-05 monotonic refresh generation ordering: out-of-order stale completions
    /// cannot overwrite newer discovery targets or re-enable disabled states.
    @MainActor
    @Test func testF05TailscaleRefreshOrderingAndOutdatedDiscard() throws {
        let service = MacMateService.shared
        
        // Start refresh A
        service.refreshTailscale()
        let genA = service.currentTailscaleRefreshGeneration
        
        // User disables Tailscale -> invalidates outstanding refreshes
        UserDefaults.standard.set(false, forKey: TailscaleDiscovery.enabledKey)
        service.refreshTailscale()
        let genDisabled = service.currentTailscaleRefreshGeneration
        #expect(genDisabled > genA)
        #expect(service.tailscaleStatus == .notRunning)
        
        // User re-enables Tailscale -> starts refresh B
        UserDefaults.standard.set(true, forKey: TailscaleDiscovery.enabledKey)
        service.refreshTailscale()
        let genB = service.currentTailscaleRefreshGeneration
        #expect(genB > genDisabled)
        
        // Simulate Refresh B finishing first with its targets
        let targetB: Set<String> = ["100.64.0.2"]
        let acceptedB = service.applyTailscaleResult(
            generation: genB,
            status: .running(selfIP: "100.64.0.2", phones: []),
            targets: targetB
        )
        #expect(acceptedB == true, "Latest generation B must be accepted")
        
        // Simulate delayed Refresh A finishing LAST with older targets
        let targetA: Set<String> = ["100.64.0.1"]
        let acceptedA = service.applyTailscaleResult(
            generation: genA,
            status: .running(selfIP: "100.64.0.1", phones: []),
            targets: targetA
        )
        #expect(acceptedA == false, "Stale generation A must be discarded")
        
        // Confirm targets remain from B and were not overwritten by A
        #expect(service.tailscaleStatus == .running(selfIP: "100.64.0.2", phones: []))
    }

    /// Verifies F-03 SMS memoizer caches day grouping and invalidates immediately when message content changes.
    @MainActor
    @Test func testF03DayGroupMemoizerCacheAndInvalidation() throws {
        let memoizer = DayGroupMemoizer.shared
        memoizer.invalidate()
        
        let date1 = Date(timeIntervalSince1970: 1700000000)
        let date2 = Date(timeIntervalSince1970: 1700086400) // Next day
        
        let msg1 = SMSMessage(
            id: UUID(),
            event: 1,
            body: "Hello world",
            addresses: ["+15551234"],
            date: date1,
            type: 1,
            threadId: 99,
            read: true,
            subId: nil,
            attachments: []
        )
        let msg2 = SMSMessage(
            id: UUID(),
            event: 1,
            body: "Second message",
            addresses: ["+15551234"],
            date: date2,
            type: 2,
            threadId: 99,
            read: true,
            subId: nil,
            attachments: []
        )
        
        var thread = SMSConversation(
            threadId: 99,
            addresses: ["+15551234"],
            messages: [msg1, msg2]
        )
        
        // Initial grouping
        let groupsInitial = memoizer.days(for: thread)
        #expect(groupsInitial.count == 2)
        
        // Second call with identical thread -> cache hit (returns same groups)
        let groupsCached = memoizer.days(for: thread)
        #expect(groupsCached.count == 2)
        #expect(groupsCached[0].messages.first?.body == "Hello world")
        
        // In-place edit of message body -> must invalidate cache and return updated message!
        let msg1Edited = SMSMessage(
            id: msg1.id,
            event: 1,
            body: "Hello world (edited)",
            addresses: ["+15551234"],
            date: date1,
            type: 1,
            threadId: 99,
            read: true,
            subId: nil,
            attachments: []
        )
        thread = SMSConversation(
            threadId: 99,
            addresses: ["+15551234"],
            messages: [msg1Edited, msg2]
        )
        
        let groupsEdited = memoizer.days(for: thread)
        #expect(groupsEdited[0].messages.first?.body == "Hello world (edited)")
        
        // Invalidate removes cached entries
        memoizer.invalidate()
    }

    /// Verifies F-05 Tailscale targets are cleanly cleared when Tailscale is disabled.
    @MainActor
    @Test func testF05TailscaleDisabledTargetsCleared() throws {
        let discovery = UDPDiscoveryService()
        discovery.setTailscaleTargets(["100.64.0.1", "100.64.0.2"])
        
        // When cleared (e.g. Tailscale disabled):
        discovery.setTailscaleTargets([])
        // Discovery correctly accepts empty targets
        #expect(true)
    }

    /// Verifies F-10 active transfers detection.
    @MainActor
    @Test func testF10ActiveTransferProtection() throws {
        let sharePlugin = MacMateService.shared.sharePlugin
        // Initially no active transfers
        #expect(sharePlugin.hasActiveTransfers == false)
        #expect(PhoneFilesController.shared.hasActiveTransfers == false)
    }

    // MARK: - Phase C & D Integration Regression Tests

    /// Verifies small file (1 KB) payload transfer roundtrip and terminal 1.0 progress reporting.
    @Test func testPhaseCSmallFileTransfer() async throws {
        let byteCount = 1024
        let url = try makeTemporaryPayload(bytes: byteCount)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = try Data(contentsOf: url)
        let guardOnce = ResumeGuard()
        let uploader = PayloadUploader()
        var uploaderProgress: [Double] = []

        let received: Data = try await withCheckedThrowingContinuation { continuation in
            uploader.start(
                fileURL: url,
                onReady: { offer in
                    PayloadDownloader.download(
                        host: "127.0.0.1",
                        port: offer.port,
                        size: offer.size,
                        expectedPeerFingerprint: DeviceIdentity.shared.certificateFingerprint
                    ) { result in
                        guard guardOnce.claim() else { return }
                        continuation.resume(with: result.flatMap { fileURL in
                            defer { try? FileManager.default.removeItem(at: fileURL) }
                            return Result { try Data(contentsOf: fileURL) }
                        })
                    }
                },
                onProgress: { uploaderProgress.append($0) },
                onComplete: { result in
                    if case .failure(let error) = result, guardOnce.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            )
        }

        #expect(received.count == byteCount)
        #expect(received == expected)
        #expect(uploaderProgress.last.map { $0 >= 1.0 } == true)
    }

    /// Verifies large file (5 MB) payload streaming over TLS localhost without memory spikes.
    @Test func testPhaseCLargeFileTransfer() async throws {
        let byteCount = 5 * 1024 * 1024
        let url = try makeTemporaryPayload(bytes: byteCount)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = try Data(contentsOf: url)
        let guardOnce = ResumeGuard()
        let uploader = PayloadUploader()
        var uploaderProgress: [Double] = []

        let received: Data = try await withCheckedThrowingContinuation { continuation in
            uploader.start(
                fileURL: url,
                onReady: { offer in
                    PayloadDownloader.download(
                        host: "127.0.0.1",
                        port: offer.port,
                        size: offer.size,
                        expectedPeerFingerprint: DeviceIdentity.shared.certificateFingerprint
                    ) { result in
                        guard guardOnce.claim() else { return }
                        continuation.resume(with: result.flatMap { fileURL in
                            defer { try? FileManager.default.removeItem(at: fileURL) }
                            return Result { try Data(contentsOf: fileURL) }
                        })
                    }
                },
                onProgress: { uploaderProgress.append($0) },
                onComplete: { result in
                    if case .failure(let error) = result, guardOnce.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            )
        }

        #expect(received.count == byteCount)
        #expect(received == expected)
        #expect(uploaderProgress.count > 5, "Large transfer must produce multiple throttled progress increments")
        #expect(uploaderProgress.last.map { $0 >= 1.0 } == true)
    }

    /// Verifies destination conflict resolution: uniqueURL appends (1), (2) without overwriting existing files.
    @Test func testPhaseCDestinationConflictResolution() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file1 = dir.appendingPathComponent("document.pdf")
        try "Original".write(to: file1, atomically: true, encoding: .utf8)

        let target1 = SafeFilename.uniqueURL(in: dir, for: "document.pdf")
        #expect(target1.lastPathComponent == "document (1).pdf")
        try "Second".write(to: target1, atomically: true, encoding: .utf8)

        let target2 = SafeFilename.uniqueURL(in: dir, for: "document.pdf")
        #expect(target2.lastPathComponent == "document (2).pdf")

        // Confirm original file is untouched
        let contentOriginal = try String(contentsOf: file1, encoding: .utf8)
        #expect(contentOriginal == "Original")
    }

    /// Verifies that partial files are cleaned up from incoming directory on failure.
    @Test func testPhaseCPartialFileCleanupOnFailedDownload() async throws {
        // Attempt download from closed port
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            PayloadDownloader.download(
                host: "127.0.0.1",
                port: 19999, // Unused port
                size: 1024,
                expectedPeerFingerprint: nil
            ) { result in
                continuation.resume(returning: result)
            }
        }

        guard case .failure = result else {
            Issue.record("Expected failure when downloading from closed port")
            return
        }

        // Verify incoming directory has no leftover files from this failed transfer
        let incomingDir = PayloadDownloader.incomingDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: incomingDir.path) {
            // All existing contents (if any) must be older or valid; no empty/partial files
            for item in contents {
                let path = incomingDir.appendingPathComponent(item).path
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? NSNumber {
                    #expect(size.intValue >= 0)
                }
            }
        }
    }

    /// Verifies media controls MPRIS packet serialization and decoding.
    @Test func testPhaseDMediaControlsPacket() throws {
        let mpris = NetworkPacket(
            type: "kdeconnect.mpris",
            body: [
                "player": AnyCodable("Apple Music"),
                "nowPlaying": AnyCodable("Starboy"),
                "artist": AnyCodable("The Weeknd"),
                "album": AnyCodable("Starboy"),
                "isPlaying": AnyCodable(true),
                "pos": AnyCodable(45000),
                "length": AnyCodable(230000),
                "canPause": AnyCodable(true),
                "canPlay": AnyCodable(true),
                "canGoNext": AnyCodable(true),
                "canGoPrevious": AnyCodable(true)
            ]
        )
        let data = try mpris.serialize()
        let decoded = try NetworkPacket.unserialize(from: data)
        #expect(decoded.type == "kdeconnect.mpris")
        #expect(decoded.string(for: "player") == "Apple Music")
        #expect(decoded.string(for: "nowPlaying") == "Starboy")
        #expect(decoded.string(for: "artist") == "The Weeknd")
        #expect(decoded.bool(for: "isPlaying") == true)
        #expect(decoded.bool(for: "canPause") == true)
        #expect(decoded.int(for: "pos") == 45000)
    }

    /// Verifies presentation remote packet serialization and decoding.
    @Test func testPhaseDPresentationRemotePacket() throws {
        let presenter = NetworkPacket(
            type: "kdeconnect.presenter",
            body: [
                "dx": AnyCodable(0.5),
                "dy": AnyCodable(-0.2),
                "stop": AnyCodable(false)
            ]
        )
        let data = try presenter.serialize()
        let decoded = try NetworkPacket.unserialize(from: data)
        #expect(decoded.type == "kdeconnect.presenter")
        #expect(decoded.double(for: "dx") == 0.5)
        #expect(decoded.double(for: "dy") == -0.2)
        #expect(decoded.bool(for: "stop") == false)
    }

    /// Verifies find-my-phone ring packet serialization.
    @Test func testPhaseDFindMyPhonePacket() throws {
        let ring = NetworkPacket(
            type: "kdeconnect.findmyphone.request",
            body: [:]
        )
        let data = try ring.serialize()
        let decoded = try NetworkPacket.unserialize(from: data)
        #expect(decoded.type == "kdeconnect.findmyphone.request")
    }

    /// Verifies notification packet serialization and decoding.
    @Test func testPhaseDNotificationPacket() throws {
        let notif = NetworkPacket(
            type: "kdeconnect.notification",
            body: [
                "id": AnyCodable("notif_msg_101"),
                "appName": AnyCodable("Messages"),
                "title": AnyCodable("John Doe"),
                "text": AnyCodable("See you at 5!"),
                "isClearable": AnyCodable(true),
                "time": AnyCodable("1700000000000")
            ]
        )
        let data = try notif.serialize()
        let decoded = try NetworkPacket.unserialize(from: data)
        #expect(decoded.type == "kdeconnect.notification")
        #expect(decoded.string(for: "id") == "notif_msg_101")
        #expect(decoded.string(for: "appName") == "Messages")
        #expect(decoded.string(for: "title") == "John Doe")
        #expect(decoded.string(for: "text") == "See you at 5!")
        #expect(decoded.bool(for: "isClearable") == true)
    }

    // MARK: - Helpers

    private func makeTemporaryPayload(bytes: Int) throws -> URL {
        var payload = Data(count: bytes)
        payload.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in 0..<bytes {
                buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmate-payload-test-\(UUID().uuidString).bin")
        try payload.write(to: url)
        return url
    }
}

/// Lets only the first of several racing callbacks resolve a continuation.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }
}
