import Foundation

public enum AgentOperation: String, Codable, Sendable {
    case create
    case start
    case wait
    case signal
    case resize
    case closeStdin
    case delete
    case copyIn
    case copyOut
    case copyList
    case ping
    case shutdown
}

public struct AgentHello: Codable, Equatable, Sendable {
    public var version: UInt16
    public var capabilities: [String]
    public var build: String?

    public init(version: UInt16 = AgentProtocol.version, capabilities: [String], build: String? = nil) {
        self.version = version
        self.capabilities = capabilities
        self.build = build
    }
}

public struct AgentRLimit: Codable, Equatable, Sendable {
    public var resource: String
    public var soft: UInt64
    public var hard: UInt64

    public init(resource: String, soft: UInt64, hard: UInt64) {
        self.resource = resource
        self.soft = soft
        self.hard = hard
    }
}

public struct AgentProcessConfiguration: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String]
    public var workingDirectory: String
    public var terminal: Bool
    /// OCI user expression: user, uid, user:group, or uid:gid.
    /// When present the guest resolves it against its own account database.
    public var user: String?
    public var uid: UInt32
    public var gid: UInt32
    public var supplementalGroups: [UInt32]
    public var rlimits: [AgentRLimit]
    public var columns: UInt16
    public var rows: UInt16

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String] = [],
        workingDirectory: String = "/",
        terminal: Bool = false,
        user: String? = nil,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        supplementalGroups: [UInt32] = [],
        rlimits: [AgentRLimit] = [],
        columns: UInt16 = 80,
        rows: UInt16 = 24
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        self.uid = uid
        self.gid = gid
        self.supplementalGroups = supplementalGroups
        self.rlimits = rlimits
        self.columns = columns
        self.rows = rows
    }
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var operation: AgentOperation
    public var process: AgentProcessConfiguration?
    public var signal: Int32?
    public var columns: UInt16?
    public var rows: UInt16?
    public var path: String?
    public var destination: String?
    public var entryType: String?
    public var mode: UInt32?
    public var size: UInt64?
    public var linkTarget: String?
    public var createParents: Bool?

    public init(operation: AgentOperation, process: AgentProcessConfiguration? = nil) {
        self.operation = operation
        self.process = process
    }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var code: String?
    public var message: String?
    public var pid: Int32?
    public var exitCode: Int32?
    public var exitedAtMilliseconds: Int64?
    public var entries: [CopyEntry]?
    public var entryType: String?
    public var mode: UInt32?
    public var size: UInt64?
    public var linkTarget: String?
    public var build: String?

    public init(ok: Bool, code: String? = nil, message: String? = nil) {
        self.ok = ok
        self.code = code
        self.message = message
    }
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public var event: String
    public var exitCode: Int32?
    public var requestID: UInt64?

    public init(event: String, exitCode: Int32? = nil, requestID: UInt64? = nil) {
        self.event = event
        self.exitCode = exitCode
        self.requestID = requestID
    }
}

public struct CopyEntry: Codable, Equatable, Sendable {
    public var path: String
    public var type: String
    public var mode: UInt32
    public var size: UInt64
    public var linkTarget: String?

    public init(path: String, type: String, mode: UInt32, size: UInt64 = 0, linkTarget: String? = nil) {
        self.path = path
        self.type = type
        self.mode = mode
        self.size = size
        self.linkTarget = linkTarget
    }
}

public enum ControlCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try encoder.encode(value)
        guard data.count <= AgentProtocol.maximumControlPayload else {
            throw FrameCodecError.payloadTooLarge(data.count)
        }
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
