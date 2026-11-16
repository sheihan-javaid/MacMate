//
//  LineBufferTests.swift
//  MacMateTests
//

import Testing
import Foundation
@testable import MacMate

struct LineBufferTests {
    @Test func holdsPartialLineUntilNewline() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("hel".utf8)).isEmpty)
        #expect(buffer.append(Data("lo\nwor".utf8)) == ["hello"])
        #expect(buffer.append(Data("ld\n".utf8)) == ["world"])
    }

    @Test func keepsMultiByteCharacterSplitAcrossChunks() {
        let bytes = Array("é\n".utf8)   // 0xC3 0xA9 0x0A
        let buffer = LineBuffer()
        #expect(buffer.append(Data(bytes[0..<1])).isEmpty)
        #expect(buffer.append(Data(bytes[1...])) == ["é"])
    }

    @Test func flushReturnsLineWithoutNewlineOnce() {
        let buffer = LineBuffer()
        _ = buffer.append(Data("done".utf8))
        #expect(buffer.flush() == ["done"])
        #expect(buffer.flush().isEmpty)
    }

    @Test func manyLinesInOneChunkAndPacketSplitAcrossReads() {
        let buffer = LineBuffer()
        let burst = (0..<10_000).map { "{\"n\":\($0)}" }.joined(separator: "\n") + "\n{\"n\":"
        let first = buffer.appendBytes(Data(burst.utf8))
        #expect(first.count == 10_000)
        #expect(String(decoding: first[9_999], as: UTF8.self) == "{\"n\":9999}")
        #expect(buffer.pendingCount == 5)          // the unfinished "{\"n\":"

        let rest = buffer.appendBytes(Data("10000}\n".utf8))
        #expect(rest.map { String(decoding: $0, as: UTF8.self) } == ["{\"n\":10000}"])
        #expect(buffer.pendingCount == 0)
    }

    @Test func rawPointerAppendMatchesDataAppend() {
        let buffer = LineBuffer()
        let bytes = Array("a\n\nb\n".utf8)   // an empty line is skipped
        let lines = bytes.withUnsafeBytes { buffer.appendBytes($0.baseAddress!, count: bytes.count) }
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
    }
}
