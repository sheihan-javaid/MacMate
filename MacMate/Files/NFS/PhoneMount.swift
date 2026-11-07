//
//  PhoneMount.swift
//  MacMate
//
//  Mounts a phone as a drive: starts its NFS server on loopback, gives it a
//  local-only Bonjour name (so Finder shows "motorola-edge-50.local" rather
//  than 127.0.0.1), and mounts the share, named after the phone, with
//  mount_nfs. No administrator password is needed for any of it.
//
//  The mount is "soft": if MacMate stops answering, file operations fail after
//  a timeout instead of hanging Finder. MacMate unmounts when the phone
//  disconnects and when it quits, and cleans up after a crash at launch.
//

import AppKit
import dnssd
import Foundation

nonisolated enum MountError: LocalizedError {
    case mountFailed(String)

    var errorDescription: String? {
        switch self {
        case .mountFailed(let detail): "Couldn't mount the phone: \(detail)"
        }
    }
}

@MainActor
final class PhoneMount {
    let deviceId: String
    let name: String
    let mountPoint: URL
    private let server: PhoneNFSServer
    private var hostName: LocalHostName?

    /// Where phones are mounted. Kept out of the way; Finder lists the drives by name.
    nonisolated static var mountsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMate/Mounts", isDirectory: true)
    }

    /// Legacy directory used before migration.
    nonisolated static var legacyMountsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether/Mounts", isDirectory: true)
    }

    init(deviceId: String, name: String, router: PhoneFilesRouter) {
        self.deviceId = deviceId
        // A slash would split the path; macOS shows ":" for "/" in names anyway.
        self.name = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        mountPoint = Self.mountsDirectory.appendingPathComponent(self.name, isDirectory: true)
        server = PhoneNFSServer(name: self.name, deviceId: deviceId, router: router)
    }

    func mount() async throws {
        let port = try await server.start()

        let host = LocalHostName.register(for: name)
        hostName = host
        let serverName = host?.name ?? "localhost"

        let options = [
            "vers=3", "tcp", "port=\(port)", "mountport=\(port)",
            "soft", "intr", "timeo=100", "retrans=5",       // give up after ~50 s, never hang
            "locallocks", "nonegnamecache",
            "rsize=131072", "wsize=262144", "readahead=1",   // MacMate decides how far to read ahead
            "acregmax=10", "acdirmax=10",
            "deadtimeout=10",
        ].joined(separator: ",")

        let mountPoint = self.mountPoint
        let name = self.name

        // Coordinate directory creation and mount execution under cross-process MountLock
        let result = await MountLock.withAsyncLock { () async -> (status: Int32, output: String) in
            try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            return await Self.run("/sbin/mount_nfs", ["-o", options, "\(serverName):/\(name)", mountPoint.path])
        } ?? (status: -1, output: "Could not acquire mount coordination lock")

        guard result.status == 0 else {
            await server.stop()
            hostName?.remove()
            hostName = nil
            throw MountError.mountFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        MacMateLog("[Files] Mounted \(name) from \(serverName) port \(port)")
    }

    func unmount() async {
        // Off the main thread: a polite unmount waits for the drive to flush,
        // and answering the drive can need the main thread.
        let mountPoint = mountPoint
        var unmounted = await Task.detached { Self.safeUnmount(mountPoint) }.value
        if !unmounted {
            MacMateLog("[Files] Warning: Mount at \(mountPoint.path) could not be unmounted by syscall; invoking diskutil fallback")
            let result = await Self.run("/usr/sbin/diskutil", ["unmount", "force", mountPoint.path])
            unmounted = (result.status == 0)
        }
        await server.stop()
        hostName?.remove()
        hostName = nil
        if unmounted {
            Self.removeMountPoint(mountPoint)
        }
        MacMateLog("[Files] Unmounted \(name)")
    }

    /// Cleans up after the drive was ejected from outside MacMate.
    func stopAfterEject() async {
        let mountPoint = mountPoint
        _ = await Task.detached { Self.safeUnmount(mountPoint) }.value
        await server.stop()
        hostName?.remove()
        hostName = nil
        Self.removeMountPoint(mountPoint)
    }

    /// Unmounts synchronously, for when MacMate is quitting.
    func unmountNow() {
        let unmounted = Self.safeUnmount(mountPoint)
        hostName?.remove()
        if unmounted {
            Self.removeMountPoint(mountPoint)
        }
    }

    // MARK: - Helpers

    /// Safely unmounts a phone's NFS drive using Darwin.unmount.
    /// Strictly pre-validates mount ownership, filesystem type (NFS), child path safety, and source provenance.
    /// Attempts polite unmount first (flags = 0); if busy (EBUSY), falls back to MNT_FORCE so that an
    /// orphaned mount is never left in the kernel pointing to a terminated server (which causes macOS "Server connections interrupted" popups).
    @discardableResult
    nonisolated static func safeUnmount(_ url: URL) -> Bool {
        let canonicalPath = url.resolvingSymlinksInPath().standardized.path

        // Immediate pre-unmount revalidation:
        var st = statfs()
        guard statfs(canonicalPath, &st) == 0 else {
            MacMateLog("[Files] Pre-unmount check failed: statfs failed for \(canonicalPath) (errno \(errno)); preserving mount")
            return false
        }

        let fsType = withUnsafePointer(to: st.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        guard fsType.lowercased() == "nfs" else {
            MacMateLog("[Files] Pre-unmount check failed: filesystem is '\(fsType)' (expected 'nfs') at \(canonicalPath); preserving mount")
            return false
        }

        guard st.f_owner == getuid() else {
            MacMateLog("[Files] Pre-unmount check failed: mount owner UID \(st.f_owner) != current UID \(getuid()); preserving mount")
            return false
        }

        let onPath = withUnsafePointer(to: st.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let canonicalMountedOn = URL(fileURLWithPath: onPath).resolvingSymlinksInPath().standardized.path
        guard canonicalMountedOn == canonicalPath else {
            MacMateLog("[Files] Pre-unmount check failed: mounted-on path '\(canonicalMountedOn)' != '\(canonicalPath)'; preserving mount")
            return false
        }

        // Verify source provenance: must match local loopback / Bonjour name
        let fromName = withUnsafePointer(to: st.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let shareName = url.lastPathComponent
        guard isMatchingMountSource(fromName, expectedShareName: shareName) else {
            MacMateLog("[Files] Pre-unmount check failed: source '\(fromName)' does not match expected share '\(shareName)'; preserving mount")
            return false
        }

        // 1. Polite normal unmount first.
        let status = Darwin.unmount(canonicalPath, 0)
        if status == 0 {
            MacMateLog("[Files] Safely unmounted \(canonicalPath)")
            return true
        }

        // 2. If polite unmount failed (e.g. EBUSY because Finder or Spotlight has an open handle),
        // force the unmount. An open file or folder cannot be kept anyway once the phone is gone.
        // Forcing unmount releases open vnodes and prevents macOS NetFS from showing "Server connections interrupted".
        let err = errno
        MacMateLog("[Files] Polite unmount returned errno \(err) for \(canonicalPath); forcing unmount with MNT_FORCE")
        if Darwin.unmount(canonicalPath, MNT_FORCE) == 0 {
            MacMateLog("[Files] Forcibly unmounted \(canonicalPath)")
            return true
        } else {
            let forceErr = errno
            MacMateLog("[Files] Force unmount failed at \(canonicalPath) (errno \(forceErr))")
            return false
        }
    }

    /// Removes an empty mount folder after verifying it is not mounted and belongs to the user.
    /// Never a recursive delete: uses Darwin.rmdir, which only deletes empty directories.
    nonisolated static func removeMountPoint(_ url: URL) {
        let canonicalPath = url.resolvingSymlinksInPath().standardized.path
        guard !isMounted(url) else {
            MacMateLog("[Files] Cannot remove mount point directory \(canonicalPath) because it is still mounted")
            return
        }

        guard isSafeMountDirectoryChild(url) else {
            MacMateLog("[Files] Cannot remove directory \(canonicalPath): failed path safety check")
            return
        }

        var fileStat = stat()
        if stat(canonicalPath, &fileStat) == 0 {
            guard fileStat.st_uid == getuid() else {
                MacMateLog("[Files] Refusing to remove mount point \(canonicalPath): not owned by current user (uid \(fileStat.st_uid) != \(getuid()))")
                return
            }
        }
        let result = Darwin.rmdir(canonicalPath)
        if result == 0 {
            MacMateLog("[Files] Removed empty mount directory \(canonicalPath)")
        } else {
            MacMateLog("[Files] Preserved directory \(canonicalPath) (rmdir returned errno \(errno))")
        }
    }

    struct MountInfo {
        let path: String
        let fsTypeName: String
        let mountFromName: String
        let ownerUID: uid_t
    }

    nonisolated static func mountedFileSystems() -> [MountInfo] {
        var count: Int32 = 0
        var pointer: UnsafeMutablePointer<statfs>?
        count = getmntinfo(&pointer, MNT_NOWAIT)
        guard let pointer, count > 0 else { return [] }
        return (0..<Int(count)).compactMap { index in
            let entry = pointer[index]
            let fsType = withUnsafePointer(to: entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let onPath = withUnsafePointer(to: entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let fromName = withUnsafePointer(to: entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let canonical = URL(fileURLWithPath: onPath).resolvingSymlinksInPath().standardized.path
            return MountInfo(path: canonical, fsTypeName: fsType, mountFromName: fromName, ownerUID: entry.f_owner)
        }
    }

    nonisolated static func isMounted(_ url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardized.path
        return mountedFileSystems().contains { $0.path == canonical }
    }

    /// Verifies that an NFS mount source matches MacMate's local Bonjour or loopback export pattern:
    /// e.g. "phone-name.local:/phone-name", "localhost:/phone-name", or "127.0.0.1:/phone-name".
    nonisolated static func isMatchingMountSource(_ fromName: String, expectedShareName: String) -> Bool {
        guard let colonRange = fromName.range(of: ":/") else { return false }
        let host = String(fromName[..<colonRange.lowerBound]).lowercased()
        let share = String(fromName[colonRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard share == expectedShareName else { return false }
        return host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
    }

    /// Validates that a path is strictly an immediate child directory within the MacMate or legacy Tether mounts directory,
    /// has no directory traversal or symlink escape, and is owned by the current user.
    nonisolated static func isSafeMountDirectoryChild(_ url: URL) -> Bool {
        let canonicalCandidate = url.resolvingSymlinksInPath().standardized.path
        let canonicalMounts = mountsDirectory.resolvingSymlinksInPath().standardized.path
        let canonicalLegacy = legacyMountsDirectory.resolvingSymlinksInPath().standardized.path

        // Must not be the mounts root directory itself
        guard canonicalCandidate != canonicalMounts && canonicalCandidate != canonicalLegacy else {
            return false
        }

        let parent = URL(fileURLWithPath: canonicalCandidate).deletingLastPathComponent().resolvingSymlinksInPath().standardized.path
        guard parent == canonicalMounts || parent == canonicalLegacy else {
            return false
        }

        // Verify ownership
        var fileStat = stat()
        guard stat(canonicalCandidate, &fileStat) == 0, fileStat.st_uid == getuid() else {
            return false
        }

        return true
    }

    /// Unmounts phones left mounted by a previous run that didn't quit cleanly,
    /// and safely migrates legacy mounts from Tether/Mounts to MacMate/Mounts.
    /// Strictly ownership-aware, politely unmounts and uses MNT_FORCE fallback for busy mounts.
    static func cleanUpStaleMounts() {
        let lockResult: Void? = MountLock.withLock {
            performCleanUpStaleMounts()
        }
        if lockResult == nil {
            MacMateLog("[Files] Stale mount cleanup skipped: could not acquire cross-process mount lock.")
        }
    }

    private static func performCleanUpStaleMounts() {
        // 1. Check for other running instances of MacMate or legacy Tether across all candidate bundle IDs
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let candidateBundleIDs = [
            Bundle.main.bundleIdentifier,
            "com.subhashh.MacMate",
            "com.subhashh.Tether"
        ].compactMap { $0 }
        let uniqueBundleIDs = Set(candidateBundleIDs)

        let runningOthers = uniqueBundleIDs.flatMap { bundleId in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        }.filter { $0.processIdentifier != currentPID }

        guard runningOthers.isEmpty else {
            MacMateLog("[Files] Another instance is running (PIDs: \(runningOthers.map(\.processIdentifier))); leaving phone drives alone")
            return
        }

        // 2. Check for active file transfers
        guard !PhoneFilesController.shared.hasActiveTransfers else {
            MacMateLog("[Files] Active file transfers in progress; skipping stale mount cleanup")
            return
        }

        // 3. Exclude active mounts known to PhoneFilesController
        let activeMountPaths = PhoneFilesController.shared.activeMountPointPaths()

        let canonicalMounts = mountsDirectory.resolvingSymlinksInPath().standardized.path
        let canonicalLegacy = legacyMountsDirectory.resolvingSymlinksInPath().standardized.path
        let directoriesToCheck = [canonicalMounts, canonicalLegacy]

        let mounts = mountedFileSystems()

        for dirPath in directoriesToCheck {
            let isLegacyDirectory = (dirPath == canonicalLegacy)

            // Find mounted filesystems strictly matching our criteria:
            // - File system type must be NFS
            // - Path must be an immediate child of dirPath
            // - Ownership (statfs.f_owner) must match current user UID
            // - Source provenance (statfs.f_mntfromname) must match MacMate local pattern
            // - Must NOT be in activeMountPaths
            for mountInfo in mounts where mountInfo.fsTypeName.lowercased() == "nfs" {
                let candidateURL = URL(fileURLWithPath: mountInfo.path)
                guard mountInfo.path.hasPrefix(dirPath + "/") else { continue }
                guard isSafeMountDirectoryChild(candidateURL) else { continue }

                guard !activeMountPaths.contains(mountInfo.path) else {
                    MacMateLog("[Files] Preserving active mount at \(mountInfo.path)")
                    continue
                }

                // Verify mounting owner UID from statfs.f_owner
                guard mountInfo.ownerUID == getuid() else {
                    MacMateLog("[Files] Preserving mount at \(mountInfo.path): mount owner UID \(mountInfo.ownerUID) != current UID \(getuid())")
                    continue
                }

                // Verify source creation provenance from statfs.f_mntfromname
                let expectedShare = candidateURL.lastPathComponent
                guard isMatchingMountSource(mountInfo.mountFromName, expectedShareName: expectedShare) else {
                    MacMateLog("[Files] Preserving ambiguous mount at \(mountInfo.path) (source: '\(mountInfo.mountFromName)') — provenance not established")
                    continue
                }

                if isLegacyDirectory {
                    MacMateLog("[Files] Verified provenance of legacy leftover mount at \(mountInfo.path) (source: \(mountInfo.mountFromName)); attempting polite cleanup")
                }

                // Attempt polite normal unmount only. If it fails, preserve the mount.
                if safeUnmount(candidateURL) {
                    removeMountPoint(candidateURL)
                    MacMateLog("[Files] Safely cleaned up leftover mount \(mountInfo.path)")
                } else {
                    MacMateLog("[Files] Preserving leftover mount \(mountInfo.path) (could not be cleanly unmounted)")
                }
            }

            // Clean up any lingering empty directories that are not mounted
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath) {
                for item in items {
                    let itemURL = URL(fileURLWithPath: dirPath).appendingPathComponent(item)
                    guard isSafeMountDirectoryChild(itemURL) else { continue }
                    guard !activeMountPaths.contains(itemURL.resolvingSymlinksInPath().standardized.path) else { continue }
                    guard !isMounted(itemURL) else { continue }
                    removeMountPoint(itemURL)
                }
            }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runNow(tool, arguments))
            }
        }
    }

    @discardableResult
    nonisolated private static func runNow(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// A Bonjour host name pointing at 127.0.0.1, registered on this Mac only
/// (never announced on the network), so the drive's server has a readable name.
@MainActor
final class LocalHostName {
    let name: String
    private var connection: DNSServiceRef?
    private var record: DNSRecordRef?
    private static var taken = Set<String>()

    private init(name: String) {
        self.name = name
    }

    static func register(for deviceName: String) -> LocalHostName? {
        var base = deviceName.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "phone" }

        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }

        let host = LocalHostName(name: candidate + ".local")
        var connection: DNSServiceRef?
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else { return nil }
        var address: [UInt8] = [127, 0, 0, 1]
        var record: DNSRecordRef?
        let status = DNSServiceRegisterRecord(
            connection, &record, DNSServiceFlags(kDNSServiceFlagsShared),
            UInt32(kDNSServiceInterfaceIndexLocalOnly), host.name,
            UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), 4, &address, 120,
            { _, _, _, _, _ in }, nil
        )
        guard status == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(connection)
            return nil
        }
        DNSServiceSetDispatchQueue(connection, .main)
        host.connection = connection
        host.record = record
        taken.insert(candidate)
        return host
    }

    func remove() {
        if let connection {
            DNSServiceRefDeallocate(connection)
            self.connection = nil
        }
        Self.taken.remove(String(name.dropLast(".local".count)))
    }
}

/// Shared cross-process coordination lock for MacMate mount and cleanup operations.
/// Uses an advisory non-blocking flock on a dedicated lockfile in Application Support.
/// Does NOT affect Finder or external system processes.
final class MountLock: @unchecked Sendable {
    private static var lockURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMate/.mount_coordination.lock")
    }

    /// Executes operation while holding an exclusive non-blocking lock.
    /// If another MacMate process holds the lock, logs and returns nil.
    static func withLock<T>(_ operation: () throws -> T) rethrows -> T? {
        let url = lockURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            MacMateLog("[Files] Another MacMate process holds the mount coordination lock; skipping operation.")
            return nil
        }
        defer { flock(fd, LOCK_UN) }

        return try operation()
    }

    /// Asynchronous variant of `withLock` for async operations.
    static func withAsyncLock<T>(_ operation: () async throws -> T) async rethrows -> T? {
        let url = lockURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            MacMateLog("[Files] Another MacMate process holds the mount coordination lock; skipping operation.")
            return nil
        }
        defer { flock(fd, LOCK_UN) }

        return try await operation()
    }
}