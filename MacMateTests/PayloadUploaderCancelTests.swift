//
//  PayloadUploaderCancelTests.swift
//  MacMateTests
//

import Testing
import Foundation
@testable import MacMate

struct PayloadUploaderCancelTests {
    /// Counts completions, and lets the test resume its continuation only once
    /// so a repeat is reported as a failure rather than crashing the test host.
    private final class Completions: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<Void, Error>] = []
        var all: [Result<Void, Error>] { lock.withLock { results } }
        /// Returns true for the first completion only.
        func record(_ result: Result<Void, Error>) -> Bool {
            lock.withLock { results.append(result); return results.count == 1 }
        }
    }

    /// Cancelling must report through the caller's completion, or code waiting
    /// on it (SharePlugin's send queue) never resumes; and it must report
    /// exactly once, including when the accept step runs after the cancel.
    @Test func cancelReportsThroughCompletionExactlyOnce() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmate-cancel-\(UUID().uuidString)")
        try Data(repeating: 1, count: 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let uploader = PayloadUploader()
        let completions = Completions()
        let first: Result<Void, Error> = await withCheckedContinuation { continuation in
            uploader.start(
                fileURL: file,
                onReady: { _ in uploader.cancel() },
                onProgress: { _ in },
                onComplete: { result in
                    if completions.record(result) { continuation.resume(returning: result) }
                }
            )
        }

        guard case .failure(let error) = first, case PayloadError.cancelled = error else {
            Issue.record("expected .cancelled, got \(first)")
            return
        }

        // The accept step is queued behind the cancel; give it time to run.
        try await Task.sleep(for: .milliseconds(500))
        #expect(completions.all.count == 1, "completion ran \(completions.all.count) times")
    }
}
