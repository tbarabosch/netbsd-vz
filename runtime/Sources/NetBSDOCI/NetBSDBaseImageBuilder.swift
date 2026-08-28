import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation

public struct NetBSDBaseImageBuilder {
    public static let version = "netbsd-base-image/1"

    public init() {}

    public func build(baseSet: URL, etcSet: URL, output: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else {
            throw NetBSDOCIError.io("OCI output already exists: \(output.path)")
        }
        for set in [baseSet, etcSet] {
            let values = try set.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw NetBSDOCIError.io("NetBSD set is not a regular file: \(set.path)")
            }
        }

        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).part-\(UUID().uuidString)")
        let work = fm.temporaryDirectory
            .appendingPathComponent("netbsd-oci-base-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary.appendingPathComponent("blobs/sha256"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        defer {
            try? fm.removeItem(at: work)
            if !fm.fileExists(atPath: output.path) { try? fm.removeItem(at: temporary) }
        }

        var layers: [Descriptor] = []
        var diffIDs: [String] = []
        for (index, set) in [baseSet, etcSet].enumerated() {
            let uncompressed = work.appendingPathComponent("layer-\(index).tar")
            let compressed = work.appendingPathComponent("layer-\(index).tar.gz")
            try transcode(source: set, sourceFilter: .xz, destination: uncompressed, destinationFilter: .none)
            try deterministicGzip(source: uncompressed, destination: compressed)
            diffIDs.append("sha256:\(try sha256(uncompressed))")
            layers.append(try storeBlob(
                compressed,
                mediaType: MediaTypes.imageLayerGzip,
                in: temporary
            ))
        }

        let image = ContainerizationOCI.Image(
            created: "2026-08-28T00:00:00Z",
            author: "container-runtime-netbsd contributors",
            architecture: "arm64",
            os: "netbsd",
            osVersion: "11.0",
            config: ImageConfig(
                user: "0:0",
                env: ["PATH=/bin:/sbin:/usr/bin:/usr/sbin", "HOME=/root"],
                cmd: ["/bin/sh"],
                workingDir: "/",
                labels: [
                    "org.opencontainers.image.source": "https://github.com/tbarabosch/container-runtime-netbsd",
                    "org.opencontainers.image.version": "11.0",
                    "org.opencontainers.image.base.name": "NetBSD 11.0 evbarm-aarch64 release sets",
                ],
                stopSignal: "SIGTERM"
            ),
            rootfs: Rootfs(type: "layers", diffIDs: diffIDs),
            history: [
                History(created: "2026-08-28T00:00:00Z", createdBy: Self.version, comment: "NetBSD base set"),
                History(created: "2026-08-28T00:00:00Z", createdBy: Self.version, comment: "NetBSD etc set"),
            ]
        )
        let config = try storeJSON(image, mediaType: MediaTypes.imageConfig, in: temporary)
        let manifest = Manifest(
            config: config,
            layers: layers,
            annotations: [
                "org.opencontainers.image.source": "https://github.com/tbarabosch/container-runtime-netbsd",
                "org.opencontainers.image.version": "11.0",
            ]
        )
        let manifestDescriptor = try storeJSON(manifest, mediaType: MediaTypes.imageManifest, in: temporary)
        let tags = ["11.0", "11"].map { tag -> Descriptor in
            var descriptor = Descriptor(
                mediaType: manifestDescriptor.mediaType,
                digest: manifestDescriptor.digest,
                size: manifestDescriptor.size,
                annotations: ["org.opencontainers.image.ref.name": tag],
                platform: Platform(arch: "arm64", os: "netbsd")
            )
            descriptor.platform = Platform(arch: "arm64", os: "netbsd")
            return descriptor
        }
        let index = Index(manifests: tags)
        try encoded(index).write(to: temporary.appendingPathComponent("index.json"), options: .atomic)
        try encoded(["imageLayoutVersion": "1.0.0"])
            .write(to: temporary.appendingPathComponent("oci-layout"), options: .atomic)
        try fm.moveItem(at: temporary, to: output)
    }

    private func transcode(
        source: URL,
        sourceFilter: ContainerizationArchive.Filter,
        destination: URL,
        destinationFilter: ContainerizationArchive.Filter
    ) throws {
        let reader = try ArchiveReader(format: .paxRestricted, filter: sourceFilter, file: source)
        let writer = try ArchiveWriter(format: .paxRestricted, filter: destinationFilter, file: destination)
        let transaction = writer.makeTransactionWriter()
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        for (entry, stream) in reader.makeStreamingIterator() {
            try transaction.writeHeader(entry: entry)
            while true {
                let count = buffer.withUnsafeMutableBufferPointer { pointer in
                    stream.read(pointer.baseAddress!, maxLength: pointer.count)
                }
                guard count >= 0 else { throw NetBSDOCIError.invalidLayer("failed to read NetBSD set") }
                if count == 0 { break }
                try buffer.withUnsafeBytes { bytes in
                    try transaction.writeChunk(data: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
                }
            }
            try transaction.finish()
        }
        try writer.finishEncoding()
    }

    private func storeJSON<T: Encodable>(_ value: T, mediaType: String, in layout: URL) throws -> Descriptor {
        let data = try encoded(value)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: layout.appendingPathComponent("blobs/sha256/\(digest)"), options: .atomic)
        return Descriptor(mediaType: mediaType, digest: "sha256:\(digest)", size: Int64(data.count))
    }

    private func deterministicGzip(source: URL, destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw NetBSDOCIError.io("cannot create gzip layer: \(destination.path)")
        }
        let output = try FileHandle(forWritingTo: destination)
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-n", "-c", source.path]
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw NetBSDOCIError.io("failed to compress OCI layer: \(error)")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(at: destination)
            throw NetBSDOCIError.io("gzip failed while building OCI layer: \(message)")
        }
    }

    private func storeBlob(_ source: URL, mediaType: String, in layout: URL) throws -> Descriptor {
        let digest = try sha256(source)
        let size = Int64((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize!)
        try FileManager.default.copyItem(
            at: source,
            to: layout.appendingPathComponent("blobs/sha256/\(digest)")
        )
        return Descriptor(mediaType: mediaType, digest: "sha256:\(digest)", size: size)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
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
