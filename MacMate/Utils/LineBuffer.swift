//
//  LineBuffer.swift
//  MacMate
//

import Foundation

/// Turns arbitrary chunks of bytes into complete newline-terminated lines.
///
/// Each byte is scanned once, and the consumed prefix is dropped in one move
/// per chunk, so a large burst of lines costs time linear in its size. Used for
/// process output and for the packet stream.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    /// Bytes held that don't yet form a complete line.
    var pendingCount: Int { lock.withLock { pending.count } }

    /// Adds `data` and returns the bytes of every non-empty line it completed.
    func appendBytes(_ data: Data) -> [Data] {
        lock.withLock {
            pending.append(data)
            return takeLines()
        }
    }

    func appendBytes(_ bytes: UnsafeRawPointer, count: Int) -> [Data] {
        lock.withLock {
            pending.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            return takeLines()
        }
    }

    /// What is held never contains a newline, so scanning from the start only
    /// ever covers the newly added bytes. Call with the lock held.
    private func takeLines() -> [Data] {
        var lines: [Data] = []
        var consumed = 0
        pending.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count,
                  let hit = memchr(base + start, Int32(UInt8(ascii: "\n")), raw.count - start) {
                let end = base.distance(to: UnsafeRawPointer(hit))
                if end > start { lines.append(Data(raw[start..<end])) }
                start = end + 1
            }
            consumed = start
        }
        if consumed > 0 { pending.removeSubrange(0..<consumed) }
        return lines
    }

    /// Adds `data` and returns every line it completed, as text.
    func append(_ data: Data) -> [String] {
        appendBytes(data).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The last line, if the output didn't end with a newline.
    func flush() -> [String] {
        lock.withLock {
            defer { pending.removeAll() }
            let text = String(decoding: pending, as: UTF8.self)
            return text.isEmpty ? [] : [text]
        }
    }
}
