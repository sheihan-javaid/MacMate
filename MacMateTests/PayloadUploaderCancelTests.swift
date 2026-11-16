//
//  PayloadUploaderCancelTests.swift
//  MacMateTests
//

import Testing
import Foundation
@testable import MacMate

struct PayloadUploaderCancelTests {
    /// Cancelling must still report through the caller's completion, or code
    /// waiting on it (SharePlugin's send queue) never resumes.
    @Test func cancelReportsThroughCompletion() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macmate-cancel-\(UUID().uuidString)")
        try Data(repeating: 1, count: 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let uploader = PayloadUploader()
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            uploader.start(
                fileURL: file,
                onReady: { _ in uploader.cancel() },
                onProgress: { _ in },
                onComplete: { continuation.resume(returning: $0) }
            )
        }

        guard case .failure(let error) = result, case PayloadError.cancelled = error else {
            Issue.record("expected .cancelled, got \(result)")
            return
        }
    }
}
