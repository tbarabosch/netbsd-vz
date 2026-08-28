import Foundation
import Testing
@testable import NetBSDAgentProtocol

@Test func sharedVectorsEncodeAndDecode() throws {
    let url = Bundle.module.url(forResource: "frames", withExtension: "json")!
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    #expect(fixture.version == 1)

    for vector in fixture.vectors {
        let payload = try Data(hex: vector.payloadHex)
        let frame = try Frame(
            type: FrameType(rawValue: vector.type)!,
            requestID: vector.requestID,
            processID: vector.processID,
            payload: payload
        )
        let encoded = try frame.encoded()
        #expect(encoded == (try Data(hex: vector.frameHex)))

        var decoder = FrameDecoder()
        try decoder.append(encoded)
        #expect(try decoder.next() == frame)
        #expect(try decoder.next() == nil)
    }
}

@Test func fragmentedAndCombinedFrames() throws {
    let first = try Frame(type: .response, requestID: 7, payload: Data("{}".utf8))
    let second = try Frame(type: .stdout, processID: 9, payload: Data([0, 1, 2, 3]))
    let bytes = try first.encoded() + second.encoded()
    var decoder = FrameDecoder()

    for byte in bytes.prefix(31) {
        try decoder.append(Data([byte]))
        #expect(try decoder.next() == nil)
    }
    try decoder.append(Data(bytes.dropFirst(31)))
    #expect(try decoder.next() == first)
    #expect(try decoder.next() == second)
    #expect(decoder.bufferedByteCount == 0)
}

@Test func malformedAndOversizedFramesAreRejected() throws {
    var invalid = Data(repeating: 0, count: AgentProtocol.headerSize)
    invalid.replaceSubrange(0..<4, with: Data("NOPE".utf8))
    var decoder = FrameDecoder()
    try decoder.append(invalid)
    #expect(throws: FrameCodecError.invalidMagic) { try decoder.next() }

    var unsupportedVersion = try Frame(type: .request, payload: Data()).encoded()
    unsupportedVersion[5] = 2
    var versionDecoder = FrameDecoder()
    try versionDecoder.append(unsupportedVersion)
    #expect(throws: FrameCodecError.unsupportedVersion(2)) { try versionDecoder.next() }

    var unknownType = try Frame(type: .request, payload: Data()).encoded()
    unknownType[6] = 0x7f
    unknownType[7] = 0xff
    var typeDecoder = FrameDecoder()
    try typeDecoder.append(unknownType)
    #expect(throws: FrameCodecError.unknownFrameType(0x7fff)) { try typeDecoder.next() }

    #expect(throws: FrameCodecError.payloadTooLarge(AgentProtocol.maximumStreamPayload + 1)) {
        try Frame(
            type: .stdout,
            payload: Data(repeating: 0, count: AgentProtocol.maximumStreamPayload + 1)
        )
    }

    var bounded = FrameDecoder()
    try bounded.append(Data(repeating: 0, count: AgentProtocol.maximumBufferedBytes))
    #expect(throws: FrameCodecError.bufferedDataLimitExceeded) {
        try bounded.append(Data([0]))
    }
}

@Test func controlMessagesPreserveExactArguments() throws {
    let process = AgentProcessConfiguration(
        executable: "/usr/bin/printf",
        arguments: [":%s:", "one two", "x=$(id -u)"],
        environment: ["PATH=/bin:/usr/bin"],
        workingDirectory: "/tmp"
    )
    let request = AgentRequest(operation: .create, process: process)
    let roundTrip = try ControlCodec.decode(
        AgentRequest.self,
        from: ControlCodec.encode(request)
    )
    #expect(roundTrip == request)
}

private struct Fixture: Decodable {
    let version: Int
    let vectors: [Vector]

    struct Vector: Decodable {
        let name: String
        let type: UInt16
        let requestID: UInt64
        let processID: UInt64
        let payloadHex: String
        let frameHex: String
    }
}

private enum HexError: Error { case invalid }

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw HexError.invalid }
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { throw HexError.invalid }
            append(byte)
            index = end
        }
    }
}
