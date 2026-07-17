import XCTest
@testable import SpacetimeDB

/// Regression tests for WebSocket message fragmentation. A large server message
/// (e.g. a big subscription snapshot) is split across multiple WS frames: a
/// leading data frame with FIN=0, then continuation frames (opcode 0x0), the
/// last with FIN=1. The transport must reassemble these into one message.
/// Before the fix, the FIN bit was ignored and continuation frames were dropped,
/// so any fragmented message was corrupted/lost.
final class FrameFragmentationTests: XCTestCase {
    private enum FrameTestError: Error {
        case malformedFrame
    }

    private let handshakeKey = "dGhlIHNhbXBsZSBub25jZQ=="

    /// Builds a single unmasked server→client WebSocket frame. Built as an
    /// explicit `[UInt8]` so the header bytes are unambiguous (avoids any
    /// `Data.append` integer-literal overload surprises).
    private func serverFrame(
        fin: Bool,
        opcode: UInt8,
        payload: Data,
        reservedBits: UInt8 = 0,
        masked: Bool = false
    ) -> Data {
        var header: [UInt8] = []
        header.append((fin ? 0x80 : 0x00) | (reservedBits & 0x70) | (opcode & 0x0F))
        let len = payload.count
        let maskBit: UInt8 = masked ? 0x80 : 0
        if len <= 125 {
            header.append(maskBit | UInt8(len))
        } else if len <= 0xFFFF {
            header.append(maskBit | 126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(maskBit | 127)
            let l = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((l >> UInt64(shift)) & 0xFF))
            }
        }
        var frame = Data(header)
        if masked {
            frame.append(contentsOf: [0, 0, 0, 0])
        }
        frame.append(payload)
        return frame
    }

    private func feed(_ transport: NWWebSocketTransport, bytes: Data) throws -> [(UInt8, Data)] {
        var buffer = bytes
        let raw = try NWWebSocketTransport.parseFrames(from: &buffer)
        return try transport.reassemble(raw)
    }

    private func decodeClientFrame(_ frame: Data) throws -> (opcode: UInt8, payload: Data) {
        guard frame.count >= 6, frame[0] & 0x80 != 0, frame[1] & 0x80 != 0 else {
            throw FrameTestError.malformedFrame
        }

        let opcode = frame[0] & 0x0F
        let marker = Int(frame[1] & 0x7F)
        var cursor = 2
        let payloadLength: Int
        if marker <= 125 {
            payloadLength = marker
        } else if marker == 126 {
            guard frame.count >= cursor + 2 else { throw FrameTestError.malformedFrame }
            payloadLength = Int(frame[cursor]) << 8 | Int(frame[cursor + 1])
            cursor += 2
        } else {
            guard frame.count >= cursor + 8 else { throw FrameTestError.malformedFrame }
            var length: UInt64 = 0
            for byte in frame[cursor..<(cursor + 8)] {
                length = (length << 8) | UInt64(byte)
            }
            guard length <= UInt64(Int.max) else { throw FrameTestError.malformedFrame }
            payloadLength = Int(length)
            cursor += 8
        }

        guard frame.count == cursor + 4 + payloadLength else {
            throw FrameTestError.malformedFrame
        }
        let mask = frame[cursor..<(cursor + 4)]
        cursor += 4

        var payload = Data(count: payloadLength)
        payload.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            for index in 0..<payloadLength {
                destination[index] = frame[cursor + index] ^ mask[mask.startIndex + (index & 3)]
            }
        }
        return (opcode, payload)
    }

    func testUnfragmentedBinaryMessagePassesThrough() throws {
        let transport = NWWebSocketTransport()
        let payload = Data((0..<200).map { UInt8($0 % 256) })
        let frame = serverFrame(fin: true, opcode: 0x2, payload: payload)

        let messages = try feed(transport, bytes: frame)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].0, 0x2)
        XCTAssertEqual(messages[0].1, payload)
    }

    func testClientFrameBuilderMasksAllPayloadLengthForms() throws {
        for size in [0, 1, 125, 126, 65_535, 65_536] {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            let decoded = try decodeClientFrame(
                NWWebSocketTransport.makeFrame(opcode: 0x2, payload: payload)
            )
            XCTAssertEqual(decoded.opcode, 0x2, "size \(size)")
            XCTAssertEqual(decoded.payload, payload, "size \(size)")
        }
    }

    func testLargeFragmentedMessageIsReassembled() throws {
        let transport = NWWebSocketTransport()
        // ~300KB, the rough scale of an 80-stroke subscription snapshot.
        let full = Data((0..<300_000).map { UInt8($0 % 251) })
        let third = full.count / 3
        let p1 = full.subdata(in: 0..<third)
        let p2 = full.subdata(in: third..<(2 * third))
        let p3 = full.subdata(in: (2 * third)..<full.count)

        var bytes = Data()
        bytes.append(serverFrame(fin: false, opcode: 0x2, payload: p1)) // start
        bytes.append(serverFrame(fin: false, opcode: 0x0, payload: p2)) // continuation
        bytes.append(serverFrame(fin: true,  opcode: 0x0, payload: p3)) // final

        let messages = try feed(transport, bytes: bytes)
        XCTAssertEqual(messages.count, 1, "fragments must collapse into one message")
        XCTAssertEqual(messages[0].0, 0x2, "reassembled message keeps the original opcode")
        XCTAssertEqual(messages[0].1, full, "reassembled payload must equal the original")
    }

    /// Fragments must reassemble even when split across separate TCP reads
    /// (the real receive loop appends partial data and re-parses).
    func testFragmentsAcrossSeparateReadsAreReassembled() throws {
        let transport = NWWebSocketTransport()
        let full = Data((0..<120_000).map { UInt8(($0 * 7) % 251) })
        let half = full.count / 2
        let p1 = full.subdata(in: 0..<half)
        let p2 = full.subdata(in: half..<full.count)

        var produced: [(UInt8, Data)] = []
        // First TCP read: only the starting fragment.
        produced += try feed(transport, bytes: serverFrame(fin: false, opcode: 0x2, payload: p1))
        XCTAssertTrue(produced.isEmpty, "no complete message until the final fragment")
        // Second TCP read: the final fragment.
        produced += try feed(transport, bytes: serverFrame(fin: true, opcode: 0x0, payload: p2))

        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].0, 0x2)
        XCTAssertEqual(produced[0].1, full)
    }

    /// A control frame (ping) interleaved with normal traffic still passes through.
    func testControlFramePassesThrough() throws {
        let transport = NWWebSocketTransport()
        let ping = serverFrame(fin: true, opcode: 0x9, payload: Data("hi".utf8))
        let messages = try feed(transport, bytes: ping)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].0, 0x9)
    }

    func testControlFrameCanInterruptFragmentedMessage() throws {
        let transport = NWWebSocketTransport()
        let first = serverFrame(fin: false, opcode: 0x2, payload: Data("first".utf8))
        let ping = serverFrame(fin: true, opcode: 0x9, payload: Data("ping".utf8))
        let last = serverFrame(fin: true, opcode: 0x0, payload: Data("last".utf8))

        XCTAssertTrue(try feed(transport, bytes: first).isEmpty)
        let control = try feed(transport, bytes: ping)
        XCTAssertEqual(control.count, 1)
        XCTAssertEqual(control[0].0, 0x9)
        let completed = try feed(transport, bytes: last)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].1, Data("firstlast".utf8))
    }

    func testPartialFrameRemainsBuffered() throws {
        let payload = Data((0..<1_000).map { UInt8($0 % 251) })
        let frame = serverFrame(fin: true, opcode: 0x2, payload: payload)
        var buffer = Data(frame.prefix(4))

        XCTAssertTrue(try NWWebSocketTransport.parseFrames(from: &buffer).isEmpty)
        XCTAssertEqual(buffer, frame.prefix(4))

        buffer.append(frame.dropFirst(4))
        let parsed = try NWWebSocketTransport.parseFrames(from: &buffer)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].payload, payload)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testUnexpectedContinuationIsRejected() throws {
        let transport = NWWebSocketTransport()
        let continuation = serverFrame(fin: true, opcode: 0x0, payload: Data("orphan".utf8))
        XCTAssertThrowsError(try feed(transport, bytes: continuation)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .unexpectedContinuation)
        }
    }

    func testNewDataFrameCannotInterruptFragment() throws {
        let transport = NWWebSocketTransport()
        _ = try feed(
            transport,
            bytes: serverFrame(fin: false, opcode: 0x2, payload: Data("first".utf8))
        )
        XCTAssertThrowsError(
            try feed(transport, bytes: serverFrame(fin: true, opcode: 0x2, payload: Data("second".utf8)))
        ) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .interruptedFragment)
        }
    }

    func testInvalidServerFramesAreRejected() {
        var reserved = serverFrame(
            fin: true,
            opcode: 0x2,
            payload: Data(),
            reservedBits: 0x40
        )
        XCTAssertThrowsError(try NWWebSocketTransport.parseFrames(from: &reserved)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .reservedBitsSet)
        }

        var masked = serverFrame(fin: true, opcode: 0x2, payload: Data(), masked: true)
        XCTAssertThrowsError(try NWWebSocketTransport.parseFrames(from: &masked)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .maskedServerFrame)
        }

        var fragmentedPing = serverFrame(fin: false, opcode: 0x9, payload: Data())
        XCTAssertThrowsError(try NWWebSocketTransport.parseFrames(from: &fragmentedPing)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .fragmentedControlFrame)
        }
    }

    func testNonCanonicalAndInvalidPayloadLengthsAreRejected() {
        var shortLengthUsing16Bits = Data([0x82, 126, 0, 125])
        XCTAssertThrowsError(try NWWebSocketTransport.parseFrames(from: &shortLengthUsing16Bits)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .invalidPayloadLength)
        }

        var shortLengthUsing64Bits = Data([0x82, 127, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF])
        XCTAssertThrowsError(try NWWebSocketTransport.parseFrames(from: &shortLengthUsing64Bits)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .invalidPayloadLength)
        }

        var highBitLength = Data([0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try NWWebSocketTransport.parseFrames(from: &highBitLength)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .invalidPayloadLength)
        }

        var oversized64BitLength = Data([0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0])
        XCTAssertThrowsError(
            try NWWebSocketTransport.parseFrames(from: &oversized64BitLength, maximumPayloadSize: 8)
        ) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .frameTooLarge(65_536))
        }
    }

    func testTextMessagesAreRejectedBeforeFragmentBuffering() throws {
        let transport = NWWebSocketTransport()
        let text = serverFrame(fin: false, opcode: 0x1, payload: Data("unsupported".utf8))

        XCTAssertThrowsError(try feed(transport, bytes: text)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .textMessageUnsupported)
        }

        let continuation = serverFrame(fin: true, opcode: 0x0, payload: Data("tail".utf8))
        XCTAssertThrowsError(try feed(transport, bytes: continuation)) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .unexpectedContinuation)
        }
    }

    func testFrameAndMessageSizeLimitsAreEnforced() throws {
        var oversizedFrame = serverFrame(
            fin: true,
            opcode: 0x2,
            payload: Data(repeating: 1, count: 9)
        )
        XCTAssertThrowsError(
            try NWWebSocketTransport.parseFrames(from: &oversizedFrame, maximumPayloadSize: 8)
        ) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .frameTooLarge(9))
        }

        let transport = NWWebSocketTransport(maximumFramePayloadSize: 8, maximumMessagePayloadSize: 12)
        _ = try feed(
            transport,
            bytes: serverFrame(fin: false, opcode: 0x2, payload: Data(repeating: 1, count: 8))
        )
        XCTAssertThrowsError(
            try feed(
                transport,
                bytes: serverFrame(fin: true, opcode: 0x0, payload: Data(repeating: 2, count: 5))
            )
        ) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .messageTooLarge(13))
        }
    }

    func testValidHandshakeIsAccepted() throws {
        let response = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: keep-alive, Upgrade\r
            Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
            Sec-WebSocket-Protocol: v2.bsatn.spacetimedb\r
            \r

            """.utf8
        )

        try NWWebSocketTransport.validateHandshakeResponse(
            response,
            key: handshakeKey,
            protocols: ["v2.bsatn.spacetimedb"]
        )
    }

    func testHandshakeRequiresSelectedSubprotocolAndValidAcceptKey() {
        let missingProtocol = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
            \r

            """.utf8
        )
        XCTAssertThrowsError(
            try NWWebSocketTransport.validateHandshakeResponse(
                missingProtocol,
                key: handshakeKey,
                protocols: ["v2.bsatn.spacetimedb"]
            )
        )

        let invalidAccept = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: invalid\r
            Sec-WebSocket-Protocol: v2.bsatn.spacetimedb\r
            \r

            """.utf8
        )
        XCTAssertThrowsError(
            try NWWebSocketTransport.validateHandshakeResponse(
                invalidAccept,
                key: handshakeKey,
                protocols: ["v2.bsatn.spacetimedb"]
            )
        )

        let unsolicitedProtocol = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
            Sec-WebSocket-Protocol: v2.bsatn.spacetimedb\r
            \r

            """.utf8
        )
        XCTAssertThrowsError(
            try NWWebSocketTransport.validateHandshakeResponse(
                unsolicitedProtocol,
                key: handshakeKey,
                protocols: []
            )
        )

        let wrongHTTPVersion = Data(
            """
            HTTP/2 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
            \r

            """.utf8
        )
        XCTAssertThrowsError(
            try NWWebSocketTransport.validateHandshakeResponse(
                wrongHTTPVersion,
                key: handshakeKey,
                protocols: []
            )
        )
    }

    func testHandshakeRequestRejectsHeaderInjection() throws {
        let url = try XCTUnwrap(URL(string: "wss://example.com/socket?q=a%20b"))
        let request = try NWWebSocketTransport.makeHandshakeRequest(
            url: url,
            key: handshakeKey,
            protocols: ["v2.bsatn.spacetimedb"],
            headers: [
                "Authorization": "Bearer token",
                "Sec-WebSocket-Key": "ignored",
            ]
        )
        let requestString = try XCTUnwrap(String(data: request, encoding: .utf8))
        XCTAssertTrue(requestString.hasPrefix("GET /socket?q=a%20b HTTP/1.1\r\n"))
        XCTAssertTrue(requestString.contains("Authorization: Bearer token\r\n"))
        XCTAssertFalse(requestString.contains("Sec-WebSocket-Key: ignored"))

        XCTAssertThrowsError(
            try NWWebSocketTransport.makeHandshakeRequest(
                url: url,
                key: handshakeKey,
                protocols: ["v2.bsatn.spacetimedb"],
                headers: ["Authorization": "Bearer token\r\nInjected: true"]
            )
        ) { error in
            XCTAssertEqual(error as? WebSocketTransportError, .invalidRequestHeader("Authorization"))
        }

        XCTAssertThrowsError(
            try NWWebSocketTransport.makeHandshakeRequest(
                url: url,
                key: handshakeKey,
                protocols: ["invalid protocol"],
                headers: [:]
            )
        ) { error in
            XCTAssertEqual(
                error as? WebSocketTransportError,
                .invalidRequestHeader("Sec-WebSocket-Protocol")
            )
        }
    }

    func testClosePayloadValidation() throws {
        try NWWebSocketTransport.validateClosePayload(Data())
        try NWWebSocketTransport.validateClosePayload(Data([0x03, 0xE8]) + Data("normal".utf8))

        XCTAssertThrowsError(try NWWebSocketTransport.validateClosePayload(Data([0x03]))) { error in
            XCTAssertEqual(
                error as? WebSocketTransportError,
                .invalidCloseFrame("status code is truncated")
            )
        }
        XCTAssertThrowsError(try NWWebSocketTransport.validateClosePayload(Data([0x03, 0xED])))
        XCTAssertThrowsError(
            try NWWebSocketTransport.validateClosePayload(Data([0x03, 0xE8, 0xFF]))
        )
    }
}
