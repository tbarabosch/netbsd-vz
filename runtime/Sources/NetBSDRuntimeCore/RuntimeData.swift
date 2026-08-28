import CryptoKit
import Foundation
import NetBSDAgentProtocol

public struct NetBSDRuntimeData: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let supportedSchemaVersions = 1...2

    public let schemaVersion: Int
    public let diskPath: String
    public let diskSHA512: String?
    public let imageReference: String?
    public let manifestDigest: String?
    public let platformKitDigest: String?
    public let assemblerVersion: String?

    public init(diskPath: String, diskSHA512: String? = nil) throws {
        self.schemaVersion = 1
        self.diskPath = try Self.validateDisk(path: diskPath).path
        self.diskSHA512 = try Self.validateSHA512(diskSHA512)
        self.imageReference = nil
        self.manifestDigest = nil
        self.platformKitDigest = nil
        self.assemblerVersion = nil
    }

    public init(
        diskPath: String,
        diskSHA512: String,
        imageReference: String,
        manifestDigest: String,
        platformKitDigest: String,
        assemblerVersion: String
    ) throws {
        guard !imageReference.isEmpty else {
            throw NetBSDRuntimeError.invalidConfiguration("OCI image reference cannot be empty")
        }
        guard Self.validOCIDigest(manifestDigest) else {
            throw NetBSDRuntimeError.invalidConfiguration("manifest digest must be a sha256 OCI digest")
        }
        guard Self.validOCIDigest(platformKitDigest) || Self.validSHA512Digest(platformKitDigest) else {
            throw NetBSDRuntimeError.invalidConfiguration("platform-kit digest is malformed")
        }
        guard !assemblerVersion.isEmpty else {
            throw NetBSDRuntimeError.invalidConfiguration("assembler version cannot be empty")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.diskPath = try Self.validateDisk(path: diskPath).path
        self.diskSHA512 = try Self.validateSHA512(diskSHA512)
        self.imageReference = imageReference
        self.manifestDigest = manifestDigest.lowercased()
        self.platformKitDigest = platformKitDigest.lowercased()
        self.assemblerVersion = assemblerVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, diskPath, diskSHA512, imageReference, manifestDigest
        case platformKitDigest, assemblerVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard Self.supportedSchemaVersions.contains(version) else {
            throw NetBSDRuntimeError.invalidConfiguration("unsupported NetBSDRuntimeData schema \(version)")
        }
        let encodedPath = try values.decode(String.self, forKey: .diskPath)
        self.schemaVersion = version
        self.diskPath = try Self.validateDisk(path: encodedPath).path
        self.diskSHA512 = try Self.validateSHA512(values.decodeIfPresent(String.self, forKey: .diskSHA512))
        self.imageReference = try values.decodeIfPresent(String.self, forKey: .imageReference)
        self.manifestDigest = try values.decodeIfPresent(String.self, forKey: .manifestDigest)
        self.platformKitDigest = try values.decodeIfPresent(String.self, forKey: .platformKitDigest)
        self.assemblerVersion = try values.decodeIfPresent(String.self, forKey: .assemblerVersion)
        if version == 2 {
            guard let imageReference, !imageReference.isEmpty,
                let manifestDigest, Self.validOCIDigest(manifestDigest),
                let platformKitDigest,
                Self.validOCIDigest(platformKitDigest) || Self.validSHA512Digest(platformKitDigest),
                let assemblerVersion, !assemblerVersion.isEmpty,
                self.diskSHA512 != nil
            else {
                throw NetBSDRuntimeError.invalidConfiguration("NetBSDRuntimeData v2 is incomplete")
            }
        }
    }

    public func validatedDisk() throws -> URL {
        let disk = try Self.validateDisk(path: diskPath)
        if let expected = diskSHA512 {
            let actual = try Self.sha512(of: disk)
            guard actual == expected else {
                throw NetBSDRuntimeError.invalidConfiguration(
                    "RAW disk SHA-512 mismatch: expected \(expected), got \(actual)"
                )
            }
        }
        return disk
    }

    private static func validateDisk(path: String) throws -> URL {
        guard (path as NSString).isAbsolutePath else {
            throw NetBSDRuntimeError.invalidConfiguration("RAW disk path must be absolute")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw NetBSDRuntimeError.invalidConfiguration(
                "cannot inspect RAW disk \(url.path): \(error.localizedDescription)"
            )
        }
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
            size.isMultiple(of: 512)
        else {
            throw NetBSDRuntimeError.invalidConfiguration(
                "RAW disk must be a non-empty, 512-byte-aligned regular file: \(url.path)"
            )
        }
        return url
    }

    public static func sha512(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA512()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateSHA512(_ digest: String?) throws -> String? {
        guard let digest else { return nil }
        let normalized = digest.lowercased()
        guard validSHA512Digest(normalized) else {
            throw NetBSDRuntimeError.invalidConfiguration(
                "disk SHA-512 must contain 128 hexadecimal characters"
            )
        }
        return normalized
    }

    private static func validSHA512Digest(_ digest: String) -> Bool {
        let value = digest.hasPrefix("sha512:") ? String(digest.dropFirst(7)) : digest
        return value.count == 128 && value.allSatisfy { "0123456789abcdef".contains($0.lowercased()) }
    }

    private static func validOCIDigest(_ digest: String) -> Bool {
        guard digest.hasPrefix("sha256:") else { return false }
        let value = digest.dropFirst(7)
        return value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0.lowercased()) }
    }
}

public enum NetBSDRuntimeError: Error, CustomStringConvertible, Equatable {
    case invalidConfiguration(String)
    case invalidState(String)
    case protocolFailure(String)
    case unsupported(String)
    case timeout(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message), .invalidState(let message),
            .protocolFailure(let message), .unsupported(let message), .timeout(let message):
            message
        }
    }
}

public struct RuntimeProcessConfiguration: Codable, Equatable, Sendable {
    public struct User: Codable, Equatable, Sendable {
        public let uid: UInt32
        public let gid: UInt32
        public let raw: String?

        public init(uid: UInt32 = 0, gid: UInt32 = 0, raw: String? = nil) {
            self.uid = uid
            self.gid = gid
            self.raw = raw
        }
    }

    public let executable: String
    public let arguments: [String]
    public let environment: [String]
    public let workingDirectory: String
    public let terminal: Bool
    public let user: User
    public let supplementalGroups: [UInt32]
    public let rlimits: [AgentRLimit]

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String] = [],
        workingDirectory: String = "/",
        terminal: Bool = false,
        user: User = .init(),
        supplementalGroups: [UInt32] = [],
        rlimits: [AgentRLimit] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        self.supplementalGroups = supplementalGroups
        self.rlimits = rlimits
    }

    public var agentConfiguration: AgentProcessConfiguration {
        AgentProcessConfiguration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            terminal: terminal,
            user: user.raw,
            uid: user.uid,
            gid: user.gid,
            supplementalGroups: supplementalGroups,
            rlimits: rlimits
        )
    }
}
