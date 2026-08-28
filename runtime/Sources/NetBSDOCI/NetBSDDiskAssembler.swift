import CryptoKit
import Darwin
import Foundation

public struct NetBSDPlatformKit: Sendable {
    public let root: URL
    public let manifestDigest: String
    public let kernel: URL
    public let bootLoader: URL
    public let bootConfig: URL
    public let tools: URL

    public init(root: URL) throws {
        let root = root.standardizedFileURL
        let manifest = root.appendingPathComponent("platform-kit.json")
        let data = try Data(contentsOf: manifest)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)
        guard decoded.schemaVersion == 1, decoded.netbsdVersion == "11.0",
            decoded.hostPlatform == "darwin/arm64", decoded.guestPlatform == "netbsd/arm64"
        else {
            throw NetBSDOCIError.invalidImage("incompatible NetBSD platform kit")
        }
        self.root = root
        self.manifestDigest = "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        self.kernel = root.appendingPathComponent("kernel/netbsd-GENERIC64")
        self.bootLoader = root.appendingPathComponent("EFI/BOOT/BOOTAA64.EFI")
        self.bootConfig = root.appendingPathComponent("EFI/BOOT/boot.cfg")
        self.tools = root.appendingPathComponent("tools/bin")
        for file in [kernel, bootLoader, bootConfig] {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw NetBSDOCIError.io("platform-kit artifact is missing: \(file.path)")
            }
        }
        for name in ["nbmakefs", "nbgpt", "nbpwd_mkdb"] {
            guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent(name).path) else {
                throw NetBSDOCIError.io("platform-kit tool is missing: \(name)")
            }
        }
        try Self.verifyPlatformKit(root: root, manifest: decoded)
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let netbsdVersion: String
        let hostPlatform: String
        let guestPlatform: String
        let kernelSHA512: String
        let efiLoaderSHA512: String
        let bootConfigSHA512: String
        let filesManifestSHA512: String
    }

    private static func verifyPlatformKit(root: URL, manifest: Manifest) throws {
        let expected = [
            "kernel/netbsd-GENERIC64": manifest.kernelSHA512,
            "EFI/BOOT/BOOTAA64.EFI": manifest.efiLoaderSHA512,
            "EFI/BOOT/boot.cfg": manifest.bootConfigSHA512,
            "tools.sha512": manifest.filesManifestSHA512,
        ]
        for (relative, digest) in expected {
            let file = root.appendingPathComponent(relative)
            guard try sha512(file) == digest.lowercased() else {
                throw NetBSDOCIError.invalidImage("platform-kit checksum mismatch: \(relative)")
            }
        }

        let checksumFile = root.appendingPathComponent("tools.sha512")
        let contents = try String(contentsOf: checksumFile, encoding: .utf8)
        for line in contents.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else {
                throw NetBSDOCIError.invalidImage("malformed platform-kit checksum manifest")
            }
            let digest = String(fields[0]).lowercased()
            var relative = String(fields[1])
            if relative.hasPrefix("./") { relative.removeFirst(2) }
            guard !relative.isEmpty, !relative.hasPrefix("/"),
                !relative.split(separator: "/").contains(".."),
                digest.count == 128,
                digest.allSatisfy({ "0123456789abcdef".contains($0) })
            else {
                throw NetBSDOCIError.invalidImage("unsafe platform-kit checksum entry")
            }
            let file = root.appendingPathComponent(relative).standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"), try sha512(file) == digest else {
                throw NetBSDOCIError.invalidImage("platform-kit checksum mismatch: \(relative)")
            }
        }
    }

    private static func sha512(_ file: URL) throws -> String {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw NetBSDOCIError.invalidImage("platform-kit artifact is not a regular file: \(file.path)")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA512()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct NetBSDDiskAssemblyRequest: Sendable {
    public let imageReference: String
    public let manifestDigest: String
    public let layers: [OCILayerSource]
    public let platformKit: NetBSDPlatformKit
    public let agent: URL
    public let cache: URL
    public let requestedStorageBytes: UInt64?

    public init(
        imageReference: String,
        manifestDigest: String,
        layers: [OCILayerSource],
        platformKit: NetBSDPlatformKit,
        agent: URL,
        cache: URL,
        requestedStorageBytes: UInt64? = nil
    ) {
        self.imageReference = imageReference
        self.manifestDigest = manifestDigest
        self.layers = layers
        self.platformKit = platformKit
        self.agent = agent
        self.cache = cache
        self.requestedStorageBytes = requestedStorageBytes
    }
}

public struct NetBSDDiskAssemblyResult: Sendable {
    public let disk: URL
    public let sha512: String
    public let storageBytes: UInt64
    public let platformKitDigest: String
    public let assemblerVersion: String
}

public final class NetBSDDiskAssembler {
    public static let version = "netbsd-oci-disk/1"

    private let fm = FileManager.default

    public init() {}

    public func assemble(_ request: NetBSDDiskAssemblyRequest) throws -> NetBSDDiskAssemblyResult {
        guard request.manifestDigest.hasPrefix("sha256:") else {
            throw NetBSDOCIError.invalidImage("manifest digest must use sha256")
        }
        guard fm.isExecutableFile(atPath: request.agent.path) else {
            throw NetBSDOCIError.io("guest agent is missing: \(request.agent.path)")
        }
        try fm.createDirectory(at: request.cache, withIntermediateDirectories: true)
        cleanupAbandonedWorkspaces(in: request.cache)
        let workspace = request.cache.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        let root = workspace.appendingPathComponent("root", isDirectory: true)
        let work = workspace.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try String(ProcessInfo.processInfo.processIdentifier).write(
            to: workspace.appendingPathComponent("owner-pid"), atomically: true, encoding: .utf8
        )
        defer { discardWorkspace(workspace) }

        let applied = try OCILayerApplier().apply(request.layers, to: root)
        try validateNetBSDRoot(root)
        var metadata = applied.metadata
        try injectRuntime(root: root, work: work, request: request, metadata: &metadata)
        let storageBytes = try storageSize(
            requested: request.requestedStorageBytes,
            regularFileBytes: applied.regularFileBytes
        )
        let key = try cacheKey(request: request, storageBytes: storageBytes)
        let entry = request.cache.appendingPathComponent(key, isDirectory: true)
        let disk = entry.appendingPathComponent("root.raw")
        let digestFile = entry.appendingPathComponent("root.raw.sha512")
        if fm.fileExists(atPath: disk.path), let digest = try? String(contentsOf: digestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !digest.isEmpty
        {
            return result(disk: disk, digest: digest, storage: storageBytes, request: request)
        }

        let lock = request.cache.appendingPathComponent(".\(key).lock", isDirectory: true)
        try acquire(lock: lock)
        defer { try? fm.removeItem(at: lock) }
        for candidate in try fm.contentsOfDirectory(at: request.cache, includingPropertiesForKeys: nil)
        where candidate.lastPathComponent.hasPrefix(".\(key).part-") {
            try? fm.removeItem(at: candidate)
        }
        if fm.fileExists(atPath: disk.path), let digest = try? String(contentsOf: digestFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !digest.isEmpty
        {
            return result(disk: disk, digest: digest, storage: storageBytes, request: request)
        }

        let partial = request.cache.appendingPathComponent(".\(key).part-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: false)
        do {
            let output = partial.appendingPathComponent("root.raw")
            try buildDisk(
                root: root,
                work: work,
                metadata: metadata,
                platformKit: request.platformKit,
                storageBytes: storageBytes,
                output: output
            )
            let digest = try sha512(output)
            try (digest + "\n").write(
                to: partial.appendingPathComponent("root.raw.sha512"), atomically: true, encoding: .utf8
            )
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: output.path)
            try fm.moveItem(at: partial, to: entry)
            return result(disk: disk, digest: digest, storage: storageBytes, request: request)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    private func result(
        disk: URL, digest: String, storage: UInt64, request: NetBSDDiskAssemblyRequest
    ) -> NetBSDDiskAssemblyResult {
        NetBSDDiskAssemblyResult(
            disk: disk,
            sha512: digest,
            storageBytes: storage,
            platformKitDigest: request.platformKit.manifestDigest,
            assemblerVersion: Self.version
        )
    }

    private func validateNetBSDRoot(_ root: URL) throws {
        for path in ["sbin/init", "bin/sh", "etc/master.passwd", "dev/MAKEDEV"] {
            guard fm.fileExists(atPath: root.appendingPathComponent(path).path) else {
                throw NetBSDOCIError.invalidImage("OCI image is not a complete NetBSD root: missing /\(path)")
            }
        }
    }

    private func injectRuntime(
        root: URL,
        work: URL,
        request: NetBSDDiskAssemblyRequest,
        metadata: inout [String: RootFileMetadata]
    ) throws {
        guard let overlay = Bundle.module.url(forResource: "runtime-overlay", withExtension: nil) else {
            throw NetBSDOCIError.io("runtime overlay resource is missing")
        }
        for relative in ["etc/fstab", "etc/rc.conf", "etc/ttys", "etc/rc.d/netbsd_vz_agent"] {
            let destination = root.appendingPathComponent(relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: overlay.appendingPathComponent(relative), to: destination)
            let mode: UInt32 = relative.contains("/rc.d/") ? 0o555 : 0o644
            try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: destination.path)
            metadata[relative] = trusted(.file, mode: mode)
        }
        let agent = root.appendingPathComponent("usr/sbin/netbsd-vz-agent")
        try fm.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: agent)
        try fm.copyItem(at: request.agent, to: agent)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: agent.path)
        metadata["usr/sbin/netbsd-vz-agent"] = trusted(.file, mode: 0o555)

        let kernel = root.appendingPathComponent("netbsd")
        try? fm.removeItem(at: kernel)
        try fm.copyItem(at: request.platformKit.kernel, to: kernel)
        metadata["netbsd"] = trusted(.file, mode: 0o555)

        let master = root.appendingPathComponent("etc/master.passwd")
        let passwordText = try String(contentsOf: master, encoding: .utf8)
        let locked = passwordText.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("root:") else { return String(line) }
            var fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if fields.count > 1 { fields[1] = "*" }
            return fields.joined(separator: ":")
        }.joined(separator: "\n")
        let input = work.appendingPathComponent("master.passwd")
        try locked.write(to: input, atomically: true, encoding: .utf8)
        try run(
            request.platformKit.tools.appendingPathComponent("nbpwd_mkdb"),
            ["-L", "-p", "-d", root.path, input.path]
        )
        for path in ["etc/master.passwd", "etc/passwd", "etc/pwd.db", "etc/spwd.db"] {
            if fm.fileExists(atPath: root.appendingPathComponent(path).path) {
                metadata[path] = trusted(.file, mode: path.contains("spwd") || path.contains("master") ? 0o600 : 0o644)
            }
        }
    }

    private func trusted(_ kind: RootFileMetadata.Kind, mode: UInt32) -> RootFileMetadata {
        RootFileMetadata(
            kind: kind, mode: mode, uid: 0, gid: 0,
            modificationTime: 1_700_000_000
        )
    }

    private func storageSize(requested: UInt64?, regularFileBytes: UInt64) throws -> UInt64 {
        let mib: UInt64 = 1024 * 1024
        let minimum = max(1024 * mib, regularFileBytes + regularFileBytes / 4 + 256 * mib)
        let required = ((minimum + 64 * mib - 1) / (64 * mib)) * (64 * mib)
        if let requested {
            guard requested >= required else {
                throw NetBSDOCIError.invalidImage(
                    "requested storage \(requested) bytes is below required \(required) bytes"
                )
            }
            return ((requested + 64 * mib - 1) / (64 * mib)) * (64 * mib)
        }
        return required
    }

    private func cacheKey(request: NetBSDDiskAssemblyRequest, storageBytes: UInt64) throws -> String {
        let value = [
            request.manifestDigest,
            request.platformKit.manifestDigest,
            "sha512:\(try sha512(request.agent))",
            Self.version,
            String(storageBytes),
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func acquire(lock: URL) throws {
        for _ in 0..<1200 {
            do {
                try fm.createDirectory(at: lock, withIntermediateDirectories: false)
                try String(ProcessInfo.processInfo.processIdentifier).write(
                    to: lock.appendingPathComponent("owner-pid"), atomically: true, encoding: .utf8
                )
                return
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                let ownerFile = lock.appendingPathComponent("owner-pid")
                if let text = try? String(contentsOf: ownerFile, encoding: .utf8),
                    let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                    Darwin.kill(pid, 0) == -1, errno == ESRCH
                {
                    try? fm.removeItem(at: lock)
                    continue
                }
                if !fm.fileExists(atPath: ownerFile.path),
                    let values = try? lock.resourceValues(forKeys: [.contentModificationDateKey]),
                    let modified = values.contentModificationDate,
                    Date().timeIntervalSince(modified) > 5
                {
                    try? fm.removeItem(at: lock)
                    continue
                }
                usleep(100_000)
            }
        }
        throw NetBSDOCIError.io("timed out waiting for image-cache lock \(lock.lastPathComponent)")
    }

    private func cleanupAbandonedWorkspaces(in cache: URL) {
        guard let candidates = try? fm.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for candidate in candidates where candidate.lastPathComponent.hasPrefix("work-") {
            let owner = candidate.appendingPathComponent("owner-pid")
            if let text = try? String(contentsOf: owner, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                if Darwin.kill(pid, 0) == 0 || errno != ESRCH { continue }
                discardWorkspace(candidate)
                continue
            }
            if let values = try? candidate.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = values.contentModificationDate,
                Date().timeIntervalSince(modified) > 60
            {
                discardWorkspace(candidate)
            }
        }
    }

    private func discardWorkspace(_ workspace: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", "u+rwX", workspace.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? fm.removeItem(at: workspace)
    }

    private func buildDisk(
        root: URL,
        work: URL,
        metadata: [String: RootFileMetadata],
        platformKit: NetBSDPlatformKit,
        storageBytes: UInt64,
        output: URL
    ) throws {
        let sector: UInt64 = 512
        let espStart: UInt64 = 2048
        let espSectors: UInt64 = 131_072
        let rootStart = espStart + espSectors
        let totalSectors = storageBytes / sector
        guard storageBytes.isMultiple(of: sector), totalSectors > rootStart + 2048 else {
            throw NetBSDOCIError.invalidImage("invalid disk storage geometry")
        }
        let rootSectors = totalSectors - rootStart - 2048
        let rootBytes = rootSectors * sector
        let espBytes = espSectors * sector

        // NetBSD intentionally ships a few execute-only directories. The host tools must
        // traverse the staging tree; the mtree specification below still supplies the
        // original OCI ownership and modes to the guest filesystem.
        try run(URL(fileURLWithPath: "/bin/chmod"), ["-R", "u+rwX", root.path])
        let spec = work.appendingPathComponent("root.mtree")
        let deviceSpec = try makeDeviceSpec(root: root)
        try (try mtree(root: root, metadata: metadata) + deviceSpec)
            .write(to: spec, atomically: true, encoding: .utf8)

        let esp = work.appendingPathComponent("esp", isDirectory: true)
        let espBoot = esp.appendingPathComponent("EFI/BOOT", isDirectory: true)
        try fm.createDirectory(at: espBoot, withIntermediateDirectories: true)
        try fm.copyItem(at: platformKit.bootLoader, to: espBoot.appendingPathComponent("BOOTAA64.EFI"))
        try fm.copyItem(at: platformKit.bootConfig, to: espBoot.appendingPathComponent("boot.cfg"))

        let rootPart = work.appendingPathComponent("root.ffs")
        let espPart = work.appendingPathComponent("esp.fat")
        let gpt = work.appendingPathComponent("gpt.raw")
        try run(platformKit.tools.appendingPathComponent("nbmakefs"), [
            "-Z", "-B", "little", "-s", String(rootBytes), "-S", String(sector),
            "-F", spec.path, "-N", root.appendingPathComponent("etc").path,
            "-t", "ffs", "-o", "version=1,bsize=16384,fsize=2048,density=8192,label=netbsd-root",
            rootPart.path, root.path,
        ])
        try run(platformKit.tools.appendingPathComponent("nbmakefs"), [
            "-Z", "-s", String(espBytes), "-S", String(sector), "-T", "1700000002",
            "-t", "msdos", "-o", "F=32,c=1,L=NETBSD_EFI", espPart.path, esp.path,
        ])
        guard fm.createFile(atPath: gpt.path, contents: nil) else {
            throw NetBSDOCIError.io("cannot create GPT template")
        }
        let gptHandle = try FileHandle(forWritingTo: gpt)
        try gptHandle.truncate(atOffset: storageBytes)
        try gptHandle.close()
        try run(platformKit.tools.appendingPathComponent("nbgpt"), ["-T", "1700000000", gpt.path, "create"])
        try run(platformKit.tools.appendingPathComponent("nbgpt"), [
            "-T", "1700000001", gpt.path, "add", "-b", String(espStart), "-s", String(espSectors),
            "-i", "1", "-l", "netbsd-esp", "-t", "efi",
        ])
        try run(platformKit.tools.appendingPathComponent("nbgpt"), [
            "-T", "1700000002", gpt.path, "add", "-b", String(rootStart), "-s", String(rootSectors),
            "-i", "2", "-l", "netbsd-root", "-t", "ffs",
        ])
        try fm.copyItem(at: gpt, to: output)
        try copy(espPart, into: output, at: espStart * sector)
        try copy(rootPart, into: output, at: rootStart * sector)
    }

    private func makeDeviceSpec(root: URL) throws -> String {
        let output = try run(
            URL(fileURLWithPath: "/bin/sh"), ["./MAKEDEV", "-s", "all", "ipty"],
            currentDirectory: root.appendingPathComponent("dev")
        )
        return output.split(separator: "\n").compactMap { line -> String? in
            let value = String(line)
            if value.hasPrefix(". type=dir") { return nil }
            return value.hasPrefix(".") ? "./dev" + String(value.dropFirst()) + "\n" : nil
        }.joined()
    }

    private func mtree(root: URL, metadata: [String: RootFileMetadata]) throws -> String {
        var paths = ["."]
        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, _ in true }
        )
        while let url = enumerator?.nextObject() as? URL {
            let prefix = root.path + "/"
            guard url.path.hasPrefix(prefix) else { continue }
            paths.append(String(url.path.dropFirst(prefix.count)))
        }
        paths.sort()
        var lines: [String] = [". type=dir mode=0755 uid=0 gid=0 time=1700000000.0"]
        for path in paths where path != "." && !path.hasPrefix("dev/") {
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let provided = metadata[path]
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let discoveredMode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o755
            let mode = provided?.mode ?? discoveredMode
            let uid = provided?.uid ?? 0
            let gid = provided?.gid ?? 0
            let time = provided?.modificationTime ?? 1_700_000_000
            var line = "./\(escape(path)) "
            if values.isSymbolicLink == true {
                let target = try fm.destinationOfSymbolicLink(atPath: url.path)
                line += "type=link link=\(escape(target))"
            } else if values.isDirectory == true {
                line += "type=dir"
            } else if values.isRegularFile == true {
                line += "type=file"
            } else { continue }
            line += String(format: " mode=%04o uid=%u gid=%u time=%lld.0", mode, uid, gid, time)
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func escape(_ value: String) -> String {
        value.utf8.map { byte -> String in
            if byte <= 0x20 || byte == 0x23 || byte == 0x3d || byte == 0x5c {
                return String(format: "\\%03o", byte)
            }
            return String(UnicodeScalar(byte))
        }.joined()
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil) throws -> String {
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("netbsd-oci-tool-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout")
        let errorURL = temporary.appendingPathComponent("stderr")
        guard fm.createFile(atPath: outputURL.path, contents: nil),
            fm.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw NetBSDOCIError.io("cannot create tool output files")
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            try? output.close()
            try? errors.close()
            throw error
        }
        process.waitUntilExit()
        try output.close()
        try errors.close()
        let stdout = try Data(contentsOf: outputURL)
        let stderr = try Data(contentsOf: errorURL)
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8) ?? "unknown error"
            throw NetBSDOCIError.io("\(executable.lastPathComponent) failed: \(message)")
        }
        return String(data: stdout, encoding: .utf8) ?? ""
    }

    private func copy(_ source: URL, into destination: URL, at offset: UInt64) throws {
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        try output.seek(toOffset: offset)
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try output.write(contentsOf: data)
        }
    }

    private func sha512(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA512()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
