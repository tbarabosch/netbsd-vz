import Foundation

public enum AgentProtocol {
    public static let version: UInt16 = 1
    public static let headerSize = 32
    public static let maximumControlPayload = 1024 * 1024
    public static let maximumStreamPayload = 64 * 1024
    public static let maximumBufferedBytes = 4 * 1024 * 1024
    public static let magic = Data([0x4e, 0x56, 0x5a, 0x41])
}

public enum FrameType: UInt16, Codable, Sendable {
    case hostHello = 1
    case guestReady = 2
    case request = 3
    case response = 4
    case event = 5
    case stdin = 6
    case stdout = 7
    case stderr = 8
    case streamEOF = 9
    case copyData = 10
    case error = 11

    public var isControl: Bool {
        switch self {
        case .hostHello, .guestReady, .request, .response, .event, .error:
            true
        default:
            false
        }
    }
}

public struct FrameHeader: Equatable, Sendable {
    public var version: UInt16
    public var type: FrameType
    public var flags: UInt32
    public var requestID: UInt64
    public var processID: UInt64
    public var payloadLength: UInt32

    public init(
        version: UInt16 = AgentProtocol.version,
        type: FrameType,
        flags: UInt32 = 0,
        requestID: UInt64,
        processID: UInt64,
        payloadLength: UInt32
    ) {
        self.version = version
        self.type = type
        self.flags = flags
        self.requestID = requestID
        self.processID = processID
        self.payloadLength = payloadLength
    }
}

public struct Frame: Equatable, Sendable {
    public var header: FrameHeader
    public var payload: Data

    public init(
        type: FrameType,
        flags: UInt32 = 0,
        requestID: UInt64 = 0,
        processID: UInt64 = 0,
        payload: Data = Data()
    ) throws {
        guard payload.count <= UInt32.max else {
            throw FrameCodecError.payloadTooLarge(payload.count)
        }
        let limit = type.isControl
            ? AgentProtocol.maximumControlPayload
            : AgentProtocol.maximumStreamPayload
        guard payload.count <= limit else {
            throw FrameCodecError.payloadTooLarge(payload.count)
        }
        self.header = FrameHeader(
            type: type,
            flags: flags,
            requestID: requestID,
            processID: processID,
            payloadLength: UInt32(payload.count)
        )
        self.payload = payload
    }
}

public enum FrameCodecError: Error, Equatable, CustomStringConvertible {
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unknownFrameType(UInt16)
    case payloadTooLarge(Int)
    case bufferedDataLimitExceeded

    public var description: String {
        switch self {
        case .invalidMagic: "invalid NVZA frame magic"
        case .unsupportedVersion(let version): "unsupported NVZA version \(version)"
        case .unknownFrameType(let type): "unknown NVZA frame type \(type)"
        case .payloadTooLarge(let size): "NVZA payload is too large: \(size) bytes"
        case .bufferedDataLimitExceeded: "NVZA decoder buffer limit exceeded"
        }
    }
}

extension Frame {
    public func encoded() throws -> Data {
        let limit = header.type.isControl
            ? AgentProtocol.maximumControlPayload
            : AgentProtocol.maximumStreamPayload
        guard payload.count == Int(header.payloadLength), payload.count <= limit else {
            throw FrameCodecError.payloadTooLarge(payload.count)
        }
        var data = Data(capacity: AgentProtocol.headerSize + payload.count)
        data.append(AgentProtocol.magic)
        data.appendBigEndian(header.version)
        data.appendBigEndian(header.type.rawValue)
        data.appendBigEndian(header.flags)
        data.appendBigEndian(header.requestID)
        data.appendBigEndian(header.processID)
        data.appendBigEndian(header.payloadLength)
        data.append(payload)
        return data
    }
}

public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) throws {
        guard data.count <= AgentProtocol.maximumBufferedBytes - buffer.count else {
            throw FrameCodecError.bufferedDataLimitExceeded
        }
        buffer.append(data)
    }

    public mutating func next() throws -> Frame? {
        guard buffer.count >= AgentProtocol.headerSize else { return nil }
        guard buffer.prefix(4) == AgentProtocol.magic else {
            throw FrameCodecError.invalidMagic
        }
        let version: UInt16 = buffer.readBigEndian(at: 4)
        guard version == AgentProtocol.version else {
            throw FrameCodecError.unsupportedVersion(version)
        }
        let rawType: UInt16 = buffer.readBigEndian(at: 6)
        guard let type = FrameType(rawValue: rawType) else {
            throw FrameCodecError.unknownFrameType(rawType)
        }
        let flags: UInt32 = buffer.readBigEndian(at: 8)
        let requestID: UInt64 = buffer.readBigEndian(at: 12)
        let processID: UInt64 = buffer.readBigEndian(at: 20)
        let payloadLength: UInt32 = buffer.readBigEndian(at: 28)
        let limit = type.isControl
            ? AgentProtocol.maximumControlPayload
            : AgentProtocol.maximumStreamPayload
        guard Int(payloadLength) <= limit else {
            throw FrameCodecError.payloadTooLarge(Int(payloadLength))
        }
        let totalLength = AgentProtocol.headerSize + Int(payloadLength)
        guard buffer.count >= totalLength else { return nil }
        let payload = Data(buffer[AgentProtocol.headerSize..<totalLength])
        buffer = Data(buffer.dropFirst(totalLength))
        return Frame(
            decodedHeader: FrameHeader(
                version: version,
                type: type,
                flags: flags,
                requestID: requestID,
                processID: processID,
                payloadLength: payloadLength
            ),
            payload: payload
        )
    }
}

extension Frame {
    fileprivate init(decodedHeader: FrameHeader, payload: Data) {
        self.header = decodedHeader
        self.payload = payload
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        var value: T = 0
        for byte in self[offset..<(offset + size)] {
            value = (value << 8) | T(byte)
        }
        return value
    }
}
