import Foundation

// MARK: - Client Messages (Encoding)

/// Tag order for Rust `websocket::v2::ClientMessage`:
/// 0 = Subscribe
/// 1 = Unsubscribe
/// 2 = OneOffQuery
/// 3 = CallReducer
/// 4 = CallProcedure
public enum ClientMessage: Encodable {
    case subscribe(Subscribe)
    case unsubscribe(Unsubscribe)
    case oneOffQuery(OneOffQuery)
    case callReducer(CallReducer)
    case callProcedure(CallProcedure)

    public func encode(to encoder: Encoder) throws {}
}

extension ClientMessage: BSATNSpecialEncodable {
    public func encodeBSATN(to storage: inout BSATNStorage) throws {
        switch self {
        case .subscribe(let msg):
            storage.append(0 as UInt8)
            try msg.encodeBSATN(to: &storage)
        case .unsubscribe(let msg):
            storage.append(1 as UInt8)
            try msg.encodeBSATN(to: &storage)
        case .oneOffQuery(let msg):
            storage.append(2 as UInt8)
            try msg.encodeBSATN(to: &storage)
        case .callReducer(let msg):
            storage.append(3 as UInt8)
            try msg.encodeBSATN(to: &storage)
        case .callProcedure(let msg):
            storage.append(4 as UInt8)
            try msg.encodeBSATN(to: &storage)
        }
    }
}

@usableFromInline
struct ClientMessageWireWriter: ~Copyable {
    @usableFromInline let baseAddress: UnsafeMutablePointer<UInt8>
    @usableFromInline private(set) var offset = 0

    @inlinable @inline(__always)
    init(buffer: UnsafeMutableRawBufferPointer) {
        self.baseAddress = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
    }

    @inlinable @inline(__always)
    mutating func appendU8(_ value: UInt8) {
        baseAddress[offset] = value
        offset += 1
    }

    @inlinable @inline(__always)
    mutating func appendU32(_ value: UInt32) {
        let value = value.littleEndian
        baseAddress[offset] = UInt8(truncatingIfNeeded: value)
        baseAddress[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        baseAddress[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        baseAddress[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        offset += 4
    }

    @inlinable @inline(__always)
    mutating func appendString(_ value: String) {
        appendString(value, byteCount: value.utf8.count)
    }

    @inlinable @inline(__always)
    mutating func appendString(_ value: String, byteCount: Int) {
        appendU32(UInt32(byteCount))
        guard byteCount > 0 else { return }

        let utf8 = value.utf8
        let destination = baseAddress.advanced(by: offset)
        if utf8.withContiguousStorageIfAvailable({ source in
            destination.update(from: source.baseAddress!, count: source.count)
        }) == nil {
            var index = 0
            for byte in utf8 {
                destination[index] = byte
                index += 1
            }
        }
        offset += byteCount
    }

    @inlinable @inline(__always)
    mutating func appendData(_ value: Data) {
        appendData(value, byteCount: value.count)
    }

    @inlinable @inline(__always)
    mutating func appendData(_ value: Data, byteCount: Int) {
        appendU32(UInt32(byteCount))
        guard byteCount > 0 else { return }

        value.withUnsafeBytes { source in
            baseAddress.advanced(by: offset).update(
                from: source.bindMemory(to: UInt8.self).baseAddress!,
                count: source.count
            )
        }
        offset += byteCount
    }
}

extension ClientMessage {
    @inlinable @inline(__always)
    func encodedSize() throws -> Int {
        switch self {
        case .subscribe(let message):
            guard message.queryStrings.count <= Int(UInt32.max) else {
                throw BSATNEncodingError.lengthOutOfRange
            }
            var size = 1 + 4 + 4 + 4
            for query in message.queryStrings {
                let byteCount = query.utf8.count
                guard byteCount <= Int(UInt32.max) else {
                    throw BSATNEncodingError.lengthOutOfRange
                }
                let (nextSize, overflow) = size.addingReportingOverflow(4 + byteCount)
                guard !overflow else { throw BSATNEncodingError.lengthOutOfRange }
                size = nextSize
            }
            return size
        case .unsubscribe:
            return 1 + 4 + 4 + 1
        case .oneOffQuery(let message):
            let byteCount = message.queryString.utf8.count
            guard byteCount <= Int(UInt32.max) else {
                throw BSATNEncodingError.lengthOutOfRange
            }
            return 1 + 4 + 4 + byteCount
        case .callReducer(let message):
            return try Self.callSize(name: message.reducer, args: message.args)
        case .callProcedure(let message):
            return try Self.callSize(name: message.procedure, args: message.args)
        }
    }

    @inlinable @inline(__always)
    static func callSize(name: String, args: Data) throws -> Int {
        let nameByteCount = name.utf8.count
        guard nameByteCount <= Int(UInt32.max), args.count <= Int(UInt32.max) else {
            throw BSATNEncodingError.lengthOutOfRange
        }
        return 1 + 4 + 1 + 4 + nameByteCount + 4 + args.count
    }

    @inlinable @inline(__always)
    static func encodeCall(
        tag: UInt8,
        requestId: RequestId,
        flags: UInt8,
        name: String,
        args: Data
    ) throws -> Data {
        let nameByteCount = name.utf8.count
        let argsByteCount = args.count
        guard nameByteCount <= Int(UInt32.max), argsByteCount <= Int(UInt32.max) else {
            throw BSATNEncodingError.lengthOutOfRange
        }

        let size = 1 + 4 + 1 + 4 + nameByteCount + 4 + argsByteCount
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            var writer = ClientMessageWireWriter(buffer: buffer)
            writer.appendU8(tag)
            writer.appendU32(requestId.rawValue)
            writer.appendU8(flags)
            writer.appendString(name, byteCount: nameByteCount)
            writer.appendData(args, byteCount: argsByteCount)
            assert(writer.offset == size)
        }
        return data
    }

    @inlinable @inline(__always)
    func encodeDirectly() throws -> Data {
        switch self {
        case .callReducer(let message):
            return try Self.encodeCall(
                tag: 3,
                requestId: message.requestId,
                flags: message.flags,
                name: message.reducer,
                args: message.args
            )
        case .callProcedure(let message):
            return try Self.encodeCall(
                tag: 4,
                requestId: message.requestId,
                flags: message.flags,
                name: message.procedure,
                args: message.args
            )
        default:
            break
        }

        let size = try encodedSize()
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            var writer = ClientMessageWireWriter(buffer: buffer)
            switch self {
            case .subscribe(let message):
                writer.appendU8(0)
                writer.appendU32(message.requestId.rawValue)
                writer.appendU32(message.querySetId.rawValue)
                writer.appendU32(UInt32(message.queryStrings.count))
                for query in message.queryStrings {
                    writer.appendString(query)
                }
            case .unsubscribe(let message):
                writer.appendU8(1)
                writer.appendU32(message.requestId.rawValue)
                writer.appendU32(message.querySetId.rawValue)
                writer.appendU8(message.flags)
            case .oneOffQuery(let message):
                writer.appendU8(2)
                writer.appendU32(message.requestId.rawValue)
                writer.appendString(message.queryString)
            case .callReducer, .callProcedure:
                preconditionFailure("Call messages use the direct encoding path.")
            }
            assert(writer.offset == size)
        }
        return data
    }
}

public extension BSATNEncoder {
    @inlinable @inline(__always)
    func encode(_ value: ClientMessage) throws -> Data {
        try value.encodeDirectly()
    }
}

/// Rust: `Subscribe { request_id: u32, query_set_id: QuerySetId, query_strings: Box<[Box<str>]> }`
public struct Subscribe: Encodable, BSATNSpecialEncodable {
    public var requestId: RequestId
    public var querySetId: QuerySetId
    public var queryStrings: [String]

    public init(queryStrings: [String], requestId: RequestId, querySetId: QuerySetId = QuerySetId(rawValue: 1)) {
        self.requestId = requestId
        self.querySetId = querySetId
        self.queryStrings = queryStrings
    }

    public func encode(to encoder: Encoder) throws {}

    public func encodeBSATN(to storage: inout BSATNStorage) throws {
        try requestId.encodeBSATN(to: &storage)
        try querySetId.encodeBSATN(to: &storage)
        storage.append(UInt32(queryStrings.count))
        for query in queryStrings {
            try storage.appendString(query)
        }
    }
}

/// Rust: `Unsubscribe { request_id: u32, query_set_id: QuerySetId, flags: u8 }`
public struct Unsubscribe: Encodable, BSATNSpecialEncodable {
    public var requestId: RequestId
    public var querySetId: QuerySetId
    public var flags: UInt8

    public init(requestId: RequestId, querySetId: QuerySetId, flags: UInt8 = 0) {
        self.requestId = requestId
        self.querySetId = querySetId
        self.flags = flags
    }

    public func encode(to encoder: Encoder) throws {}

    public func encodeBSATN(to storage: inout BSATNStorage) throws {
        try requestId.encodeBSATN(to: &storage)
        try querySetId.encodeBSATN(to: &storage)
        storage.append(flags)
    }
}

/// Rust: `OneOffQuery { request_id: u32, query_string: Box<str> }`
public struct OneOffQuery: Encodable, BSATNSpecialEncodable {
    public var requestId: RequestId
    public var queryString: String

    public init(requestId: RequestId, queryString: String) {
        self.requestId = requestId
        self.queryString = queryString
    }

    public func encode(to encoder: Encoder) throws {}

    public func encodeBSATN(to storage: inout BSATNStorage) throws {
        try requestId.encodeBSATN(to: &storage)
        try storage.appendString(queryString)
    }
}

/// Rust: `CallReducer { request_id: u32, flags: u8, reducer: Box<str>, args: Bytes }`
public struct CallReducer: Encodable, BSATNSpecialEncodable {
    public var requestId: RequestId
    public var flags: UInt8
    public var reducer: String
    public var args: Data

    public init(requestId: RequestId, flags: UInt8, reducer: String, args: Data) {
        self.requestId = requestId
        self.flags = flags
        self.reducer = reducer
        self.args = args
    }

    public func encode(to encoder: Encoder) throws {}

    public func encodeBSATN(to storage: inout BSATNStorage) throws {
        try requestId.encodeBSATN(to: &storage)
        storage.append(flags)
        try storage.appendString(reducer)
        storage.append(UInt32(args.count))
        storage.append(args)
    }
}

/// Rust: `CallProcedure { request_id: u32, flags: u8, procedure: Box<str>, args: Bytes }`
public struct CallProcedure: Encodable, BSATNSpecialEncodable {
    public var requestId: RequestId
    public var flags: UInt8
    public var procedure: String
    public var args: Data

    public init(requestId: RequestId, flags: UInt8, procedure: String, args: Data) {
        self.requestId = requestId
        self.flags = flags
        self.procedure = procedure
        self.args = args
    }

    public func encode(to encoder: Encoder) throws {}

    public func encodeBSATN(to storage: inout BSATNStorage) throws {
        try requestId.encodeBSATN(to: &storage)
        storage.append(flags)
        try storage.appendString(procedure)
        storage.append(UInt32(args.count))
        storage.append(args)
    }
}
