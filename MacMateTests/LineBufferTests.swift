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
}
