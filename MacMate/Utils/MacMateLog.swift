//
//  MacMateLog.swift
//  MacMate
//

import Foundation

/// Per-user log in ~/Library/Logs/MacMate, readable only by the user. It used
/// to be /tmp/macmate.log, which any local account could read.
private nonisolated let logQueue = DispatchQueue(label: "com.subhashh.macmate.log", qos: .utility)
private nonisolated let maxLogBytes: UInt64 = 2 * 1024 * 1024
private nonisolated(unsafe) let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// Only touched on `logQueue`.
private final class LogFile: @unchecked Sendable {
    private let url: URL
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init() {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacMate", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("macmate.log")
    }

    func write(_ data: Data) {
        if handle == nil { open() }
        guard let handle else { return }
        try? handle.write(contentsOf: data)
        size += UInt64(data.count)
        if size > maxLogBytes { rotate() }
    }

    private func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    /// Keeps one previous file, so the log stays bounded.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}

private nonisolated let logFile = LogFile()

/// Logs a diagnostic line. Never pass message bodies, Wi-Fi names, URLs or
/// other content from the user's phone: the log is a file on disk.
nonisolated public func MacMateLog(_ message: String) {
    let formatted = "[\(dateFormatter.string(from: Date()))] \(message)\n"
    #if DEBUG
    print(formatted, terminator: "")
    #endif
    logQueue.async {
        guard let data = formatted.data(using: .utf8) else { return }
        logFile.write(data)
    }
}
