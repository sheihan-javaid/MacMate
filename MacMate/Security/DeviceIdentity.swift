//
//  DeviceIdentity.swift
//  MacMate
//

import Foundation
import Security
import Network
import CryptoKit

public final class DeviceIdentity: @unchecked Sendable {
    public static let shared = DeviceIdentity()

    public let deviceId: String
    public var deviceName: String
    public let certificateFingerprint: String
    public let certificatePEM: String
    public let secIdentity: SecIdentity
    public let secCertificate: SecCertificate

    /// TCP port we advertise in identity packets. Updated by the listener once it
    /// has bound, since 1716 may be taken and it then walks up to 1764.
    public var advertisedTCPPort: Int {
        get { portLock.withLock { tcpPort } }
        set { portLock.withLock { tcpPort = newValue } }
    }
    private let portLock = NSLock()
    private var tcpPort = 1716

    /// The fixed PKCS#12 password early MacMate builds used. Only tried so an
    /// existing MacMate identity can be re-wrapped with a per-install passphrase.
    private static let legacyPassphrases = ["macmate"]

    private struct Paths {
        let directory: URL
        let p12: URL
        let cert: URL
        let key: URL
        let passphrase: URL

        init(directory: URL) {
            self.directory = directory
            p12 = directory.appendingPathComponent("identity.p12")
            cert = directory.appendingPathComponent("certificate.pem")
            key = directory.appendingPathComponent("key.pem")
            passphrase = directory.appendingPathComponent("identity.pass")
        }

        var all: [URL] { [p12, cert, key, passphrase] }
    }

    private convenience init() {
        self.init(applicationSupportRoot: AppIdentity.applicationSupportRoot(), defaults: .standard)
    }

    /// Reads and writes only `applicationSupportRoot/MacMate` and the `macmate_*`
    /// keys in `defaults`. A first launch creates a new identity; nothing is
    /// imported from any other application. Tests pass their own root and defaults.
    init(applicationSupportRoot: URL, defaults: UserDefaults) {
        let fm = FileManager.default
        let paths = Paths(directory: AppIdentity.applicationSupportDirectory(root: applicationSupportRoot))

        try? fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.directory.path)

        var id = defaults.string(forKey: Self.deviceIdKey)
        let name = defaults.string(forKey: Self.deviceNameKey) ?? Host.current().localizedName ?? "Mac"

        // An identity on disk is always reused, never regenerated: replacing it
        // changes this Mac's certificate, and every phone would have to pair again.
        var identity: SecIdentity?
        if fm.fileExists(atPath: paths.p12.path) {
            identity = Self.importIdentity(paths: paths)
            if let found = identity {
                let certificateId = Self.deviceId(in: found)
                if id == nil {
                    // The saved ID is gone (preferences reset or restored without
                    // it) but the key is intact. The certificate's common name is
                    // the device ID peers pinned, so take it from there.
                    id = certificateId
                    if id != nil { MacMateLog("[DeviceIdentity] Saved device ID missing; recovered it from the certificate") }
                } else if let certificateId, certificateId != id {
                    MacMateLog("[DeviceIdentity] Saved device ID differs from the certificate's; keeping the saved one")
                }
            }
        }

        if identity == nil || id == nil {
            // First launch, or the files on disk can't be used (corrupt, lost
            // passphrase, no recoverable ID). Anything already there is set aside
            // by renaming, never overwritten or deleted, so it can be restored.
            // Peers will see a new device and need to pair again.
            if Self.hasIdentityFiles(paths: paths) {
                MacMateLog("[DeviceIdentity] Stored identity could not be used; setting it aside and generating a new one")
                Self.quarantine(paths: paths)
            }
            id = Self.generateIdentity(paths: paths)
            identity = Self.importIdentity(paths: paths)
        }

        if let id {
            defaults.set(id, forKey: Self.deviceIdKey)
        }
        defaults.set(name, forKey: Self.deviceNameKey)

        guard let identity else {
            fatalError("MacMate could not create a TLS identity. Check that /usr/bin/openssl exists and ~/Library/Application Support/MacMate is writable.")
        }

        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let certRef else {
            fatalError("MacMate identity has no certificate")
        }

        self.deviceId = id!
        self.deviceName = name
        self.secIdentity = identity
        self.secCertificate = certRef
        self.certificatePEM = (try? String(contentsOf: paths.cert, encoding: .utf8)) ?? ""
        self.certificateFingerprint = SocketTLS.fingerprint(of: certRef).uppercased()
    }

    static let deviceIdKey = "macmate_device_id"
    static let deviceNameKey = "macmate_device_name"

    // MARK: - Identity storage

    /// Imports the PKCS#12 bundle, upgrading a legacy fixed-password bundle to
    /// the per-install passphrase on the way. Returns nil if nothing works.
    private static func importIdentity(paths: Paths) -> SecIdentity? {
        guard let p12Data = try? Data(contentsOf: paths.p12) else { return nil }

        let stored = try? String(contentsOf: paths.passphrase, encoding: .utf8)
        let candidates = [stored].compactMap { $0 } + legacyPassphrases

        for passphrase in candidates {
            guard let identity = importPKCS12(p12Data, passphrase: passphrase) else { continue }

            if passphrase != stored {
                // Re-wrap with a random passphrase so the bundle is no longer
                // protected by a password shared by every install.
                let fresh = newPassphrase()
                if FileManager.default.fileExists(atPath: paths.key.path) {
                    exportPKCS12(paths: paths, passphrase: fresh)
                    if importPKCS12((try? Data(contentsOf: paths.p12)) ?? Data(), passphrase: fresh) != nil {
                        writePassphrase(fresh, paths: paths)
                    } else {
                        // Re-wrap failed; put the working bundle back untouched.
                        try? p12Data.write(to: paths.p12, options: .atomic)
                    }
                }
            }
            return identity
        }
        return nil
    }

    private static func importPKCS12(_ data: Data, passphrase: String) -> SecIdentity? {
        // Memory-only: the identity never touches the login keychain. Keys there
        // cost ~10s on their first signature in each process (securityd ACL work)
        // and ~90ms after, which stalled every TLS handshake and could push the
        // first connection past its timeout. In memory a signature takes well
        // under a millisecond, and there is nothing for macOS to prompt about.
        let options: [CFString: Any] = [
            kSecImportExportPassphrase: passphrase,
            kSecImportToMemoryOnly: true
        ]

        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else { return nil }
        let identity = value as! SecIdentity

        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, privateKey != nil else { return nil }
        return identity
    }

    /// Creates a fresh key, certificate and bundle, and returns the new device ID.
    private static func generateIdentity(paths: Paths) -> String {
        let newId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let passphrase = newPassphrase()

        runOpenSSL("""
        openssl ecparam -name prime256v1 -genkey -noout -out "$KEY" && \
        chmod 600 "$KEY" && \
        openssl req -new -x509 -key "$KEY" -out "$CERT" -days 3650 -subj "/CN=\(newId)/O=KDE/OU=KDE Connect" && \
        openssl pkcs12 -export -in "$CERT" -inkey "$KEY" -out "$P12" -passout env:MACMATE_P12_PASS
        """, paths: paths, passphrase: passphrase)

        writePassphrase(passphrase, paths: paths)
        restrictPermissions(paths: paths)
        return newId
    }

    private static func exportPKCS12(paths: Paths, passphrase: String) {
        runOpenSSL(
            #"openssl pkcs12 -export -in "$CERT" -inkey "$KEY" -out "$P12" -passout env:MACMATE_P12_PASS"#,
            paths: paths,
            passphrase: passphrase
        )
        restrictPermissions(paths: paths)
    }

    /// Runs an openssl script with paths and the passphrase passed through the
    /// environment, so neither appears in the process list.
    private static func runOpenSSL(_ script: String, paths: Paths, passphrase: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "KEY": paths.key.path,
            "CERT": paths.cert.path,
            "P12": paths.p12.path,
            "MACMATE_P12_PASS": passphrase
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            MacMateLog("[DeviceIdentity] openssl failed to launch: \(error)")
        }
    }

    private static func storedOrNewPassphrase(paths: Paths) -> String {
        if let stored = try? String(contentsOf: paths.passphrase, encoding: .utf8), !stored.isEmpty {
            return stored
        }
        let fresh = newPassphrase()
        writePassphrase(fresh, paths: paths)
        return fresh
    }

    private static func newPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func writePassphrase(_ passphrase: String, paths: Paths) {
        try? Data(passphrase.utf8).write(to: paths.passphrase, options: .atomic)
        restrictPermissions(paths: paths)
    }

    private static func restrictPermissions(paths: Paths) {
        for url in paths.all where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func hasIdentityFiles(paths: Paths) -> Bool {
        paths.all.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The device ID a certificate was issued for: its common name.
    static func deviceId(in identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        var commonName: CFString?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
              let value = commonName as String?,
              value.count >= 8,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return value
    }

    /// Sets every identity file aside under a new name. Never overwrites an earlier
    /// set-aside file, and never deletes anything.
    private static func quarantine(paths: Paths) {
        let stamp = Int(Date().timeIntervalSince1970)
        for url in paths.all where FileManager.default.fileExists(atPath: url.path) {
            var aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).broken-\(stamp)")
            var attempt = 1
            while FileManager.default.fileExists(atPath: aside.path) {
                aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).broken-\(stamp)-\(attempt)")
                attempt += 1
            }
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    public func createSecIdentityProtocol() -> sec_identity_t? {
        sec_identity_create(secIdentity)
    }

    public func toDeviceInfo(tcpPort: Int? = nil) -> DeviceInfo {
        DeviceInfo(
            deviceId: deviceId,
            deviceName: deviceName,
            deviceType: .laptop,
            protocolVersion: NetworkPacket.protocolVersion,
            incomingCapabilities: DeviceInfo.defaultIncomingCapabilities,
            outgoingCapabilities: DeviceInfo.defaultOutgoingCapabilities,
            tcpPort: tcpPort ?? advertisedTCPPort
        )
    }
}

