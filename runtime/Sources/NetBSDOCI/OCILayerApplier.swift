import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation

public enum NetBSDOCIError: Error, CustomStringConvertible, Equatable {
    case invalidImage(String)
    case invalidLayer(String)
    case unsafePath(String)
    case unsupported(String)
    case io(String)

    public var description: String {
        switch self {
        case .invalidImage(let message), .invalidLayer(let message), .unsafePath(let message),
            .unsupported(let message), .io(let message):
            return message
        }
    }
}

public struct OCILayerSource: Sendable {
    public let descriptor: Descriptor
    public let diffID: String
    public let file: URL

    public init(descriptor: Descriptor, diffID: String, file: URL) {
        self.descriptor = descriptor
        self.diffID = diffID
        self.file = file
    }
}

public struct RootFileMetadata: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file, directory, symlink, hardlink
    }

    public let kind: Kind
    public let mode: UInt32
    public let uid: UInt32
    public let gid: UInt32
    public let modificationTime: Int64
    public let linkTarget: String?

    public init(
        kind: Kind,
        mode: UInt32,
        uid: UInt32,
        gid: UInt32,
        modificationTime: Int64,
        linkTarget: String? = nil
    ) {
        self.kind = kind
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.modificationTime = modificationTime
        self.linkTarget = linkTarget
    }
}

public struct OCILayerApplyResult: Sendable {
    public let metadata: [String: RootFileMetadata]
    public let regularFileBytes: UInt64
}

public final class OCILayerApplier {
    private let fileManager = FileManager.default

    public init() {}

    public func apply(_ layers: [OCILayerSource], to root: URL) throws -> OCILayerApplyResult {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var metadata: [String: RootFileMetadata] = [:]
        var totalBytes: UInt64 = 0
        for layer in layers {
            let prepared = try prepare(layer)
            defer { prepared.cleanup() }
            let scan = try scan(prepared.tar, root: root)
            for whiteout in scan.whiteouts {
                try apply(whiteout, root: root, metadata: &metadata)
            }

            let reader = try ArchiveReader(file: prepared.tar)
            let rejected = try reader.extractContents(to: root)
            let hardlinkPaths = Set(scan.hardlinks.map(\.path))
            let unsafeRejected = rejected.filter { raw in
                guard let normalized = try? normalized(raw) else { return true }
                return !hardlinkPaths.contains(normalized)
            }
            guard unsafeRejected.isEmpty else {
                throw NetBSDOCIError.unsafePath(
                    "OCI layer contains rejected paths: \(unsafeRejected.sorted().joined(separator: ", "))"
                )
            }

            for marker in scan.markerPaths {
                let markerURL = try safeURL(for: marker, under: root, checkingParents: true)
                try? fileManager.removeItem(at: markerURL)
            }
            for hardlink in scan.hardlinks {
                try materialize(hardlink: hardlink, root: root)
            }
            for (path, value) in scan.metadata {
                metadata[path] = value
            }
            totalBytes &+= scan.regularFileBytes
        }
        return OCILayerApplyResult(metadata: metadata, regularFileBytes: totalBytes)
    }

    private struct PreparedLayer {
        let tar: URL
        let cleanup: @Sendable () -> Void
    }

    private func prepare(_ layer: OCILayerSource) throws -> PreparedLayer {
        let supported = [
            MediaTypes.imageLayer, MediaTypes.imageLayerGzip, MediaTypes.imageLayerZstd,
            MediaTypes.dockerImageLayer, MediaTypes.dockerImageLayerGzip, MediaTypes.dockerImageLayerZstd,
        ]
        guard supported.contains(layer.descriptor.mediaType) else {
            throw NetBSDOCIError.unsupported("unsupported OCI layer media type \(layer.descriptor.mediaType)")
        }
        let values = try layer.file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw NetBSDOCIError.invalidLayer("layer blob is not a regular file: \(layer.file.path)")
        }
        guard Int64(values.fileSize ?? -1) == layer.descriptor.size else {
            throw NetBSDOCIError.invalidLayer("layer size does not match descriptor \(layer.descriptor.digest)")
        }
        let compressedDigest = try sha256(layer.file)
        guard layer.descriptor.digest.lowercased() == "sha256:\(compressedDigest)" else {
            throw NetBSDOCIError.invalidLayer("layer digest mismatch for \(layer.descriptor.digest)")
        }

        let prepared: PreparedLayer
        switch layer.descriptor.mediaType {
        case MediaTypes.imageLayer, MediaTypes.dockerImageLayer:
            prepared = PreparedLayer(tar: layer.file, cleanup: {})
        case MediaTypes.imageLayerGzip, MediaTypes.dockerImageLayerGzip:
            prepared = try decompressGzip(layer.file)
        case MediaTypes.imageLayerZstd, MediaTypes.dockerImageLayerZstd:
            let file = try ArchiveReader.decompressZstd(layer.file)
            prepared = PreparedLayer(tar: file) {
                ArchiveReader.cleanUpDecompressedZstd(file)
            }
        default:
            throw NetBSDOCIError.unsupported("unsupported OCI layer media type \(layer.descriptor.mediaType)")
        }
        do {
            let diffID = try sha256(prepared.tar)
            guard layer.diffID.lowercased() == "sha256:\(diffID)" else {
                throw NetBSDOCIError.invalidLayer("uncompressed DiffID mismatch for \(layer.descriptor.digest)")
            }
        } catch {
            prepared.cleanup()
            throw error
        }
        return prepared
    }

    private func decompressGzip(_ source: URL) throws -> PreparedLayer {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("netbsd-oci-gzip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let output = directory.appendingPathComponent("layer.tar")
        guard fileManager.createFile(atPath: output.path, contents: nil) else {
            throw NetBSDOCIError.io("cannot create gzip output \(output.path)")
        }
        let handle = try FileHandle(forWritingTo: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", source.path]
        process.standardOutput = handle
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: directory)
            throw NetBSDOCIError.io("failed to decompress gzip layer: \(error)")
        }
        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: directory)
            throw NetBSDOCIError.invalidLayer("gzip layer is malformed: \(source.path)")
        }
        return PreparedLayer(tar: output) { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Hardlink {
        let path: String
        let target: String
    }

    private enum Whiteout {
        case entry(String)
        case opaqueDirectory(String)
    }

    private struct Scan {
        var metadata: [String: RootFileMetadata] = [:]
        var hardlinks: [Hardlink] = []
        var whiteouts: [Whiteout] = []
        var markerPaths: [String] = []
        var regularFileBytes: UInt64 = 0
    }

    private func scan(_ tar: URL, root: URL) throws -> Scan {
        let reader = try ArchiveReader(file: tar)
        var scan = Scan()
        for (entry, _) in reader.makeStreamingIterator() {
            guard let rawPath = entry.path else {
                throw NetBSDOCIError.invalidLayer("OCI layer entry has no path")
            }
            if !rawPath.isEmpty, !rawPath.hasPrefix("/"),
                rawPath.split(separator: "/", omittingEmptySubsequences: true).allSatisfy({ $0 == "." })
            {
                guard entry.fileType == .directory else {
                    throw NetBSDOCIError.unsafePath("OCI archive root entry is not a directory")
                }
                continue
            }
            let path = try normalized(rawPath)
            _ = try safeURL(for: path, under: root, checkingParents: false)
            guard entry.xattrs.isEmpty else {
                throw NetBSDOCIError.unsupported("extended attributes are not supported in v1: \(path)")
            }
            let basename = (path as NSString).lastPathComponent
            let parent = (path as NSString).deletingLastPathComponent
            if basename == ".wh..wh..opq" {
                scan.whiteouts.append(.opaqueDirectory(parent))
                scan.markerPaths.append(path)
                continue
            }
            if basename.hasPrefix(".wh.") {
                let targetName = String(basename.dropFirst(4))
                guard !targetName.isEmpty else {
                    throw NetBSDOCIError.invalidLayer("malformed OCI whiteout \(path)")
                }
                let target = parent.isEmpty ? targetName : "\(parent)/\(targetName)"
                scan.whiteouts.append(.entry(target))
                scan.markerPaths.append(path)
                continue
            }
            let kind: RootFileMetadata.Kind
            if let hardlink = entry.hardlink {
                let target = try normalized(hardlink)
                scan.hardlinks.append(Hardlink(path: path, target: target))
                kind = .hardlink
            } else {
                switch entry.fileType {
                case .regular:
                    kind = .file
                    if let size = entry.size, size > 0 { scan.regularFileBytes &+= UInt64(size) }
                case .directory: kind = .directory
                case .symbolicLink: kind = .symlink
                case .characterSpecial, .blockSpecial, .socket, .namedPipe:
                    throw NetBSDOCIError.unsupported("special files are not supported in OCI layers: \(path)")
                default:
                    throw NetBSDOCIError.unsupported("unknown archive entry type: \(path)")
                }
            }
            scan.metadata[path] = RootFileMetadata(
                kind: kind,
                mode: UInt32(entry.permissions & 0o7777),
                uid: UInt32(entry.owner ?? 0),
                gid: UInt32(entry.group ?? 0),
                modificationTime: Int64(entry.modificationDate?.timeIntervalSince1970 ?? 0),
                linkTarget: kind == .symlink ? entry.symlinkTarget : entry.hardlink
            )
        }
        return scan
    }

    private func apply(_ whiteout: Whiteout, root: URL, metadata: inout [String: RootFileMetadata]) throws {
        switch whiteout {
        case .entry(let path):
            let url = try safeURL(for: path, under: root, checkingParents: true)
            if fileManager.fileExists(atPath: url.path) || isSymbolicLink(url) {
                try fileManager.removeItem(at: url)
            }
            metadata = metadata.filter { key, _ in key != path && !key.hasPrefix(path + "/") }
        case .opaqueDirectory(let path):
            let url = try safeURL(for: path, under: root, checkingParents: true)
            if isSymbolicLink(url) {
                throw NetBSDOCIError.unsafePath("opaque whiteout targets a symlink: \(path)")
            }
            if fileManager.fileExists(atPath: url.path) {
                for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try fileManager.removeItem(at: child)
                }
            }
            let prefix = path.isEmpty ? "" : path + "/"
            metadata = metadata.filter { key, _ in !key.hasPrefix(prefix) || key == path }
        }
    }

    private func materialize(hardlink: Hardlink, root: URL) throws {
        let source = try safeURL(for: hardlink.target, under: root, checkingParents: true)
        let destination = try safeURL(for: hardlink.path, under: root, checkingParents: true)
        guard !isSymbolicLink(source), fileManager.fileExists(atPath: source.path) else {
            throw NetBSDOCIError.invalidLayer("hardlink target is missing or unsafe: \(hardlink.target)")
        }
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.linkItem(at: source, to: destination)
        } catch {
            throw NetBSDOCIError.io("cannot create hardlink \(hardlink.path): \(error)")
        }
    }

    private func normalized(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\0") else {
            throw NetBSDOCIError.unsafePath("unsafe OCI member path: \(raw)")
        }
        var components: [Substring] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != ".." else {
                throw NetBSDOCIError.unsafePath("OCI member escapes root: \(raw)")
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            throw NetBSDOCIError.unsafePath("OCI member path is empty: \(raw)")
        }
        let value = components.joined(separator: "/")
        guard value.utf8.count <= 4096 else {
            throw NetBSDOCIError.unsafePath("OCI member path is too long")
        }
        return value
    }

    private func safeURL(for path: String, under root: URL, checkingParents: Bool) throws -> URL {
        let root = root.standardizedFileURL
        let value = root.appendingPathComponent(path).standardizedFileURL
        guard value.path.hasPrefix(root.path + "/") else {
            throw NetBSDOCIError.unsafePath("path escapes OCI staging root: \(path)")
        }
        if checkingParents {
            var current = root
            let components = path.split(separator: "/")
            for component in components.dropLast() {
                current.appendPathComponent(String(component))
                if isSymbolicLink(current) {
                    throw NetBSDOCIError.unsafePath("path traverses symlink: \(path)")
                }
            }
        }
        return value
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink == true
    }

    private func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
