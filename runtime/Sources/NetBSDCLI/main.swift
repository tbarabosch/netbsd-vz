import ArgumentParser
import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Darwin
import Foundation
import NetBSDOCI
import NetBSDRuntimeCore

@main
struct NetBSDCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "netbsd",
        abstract: "Create and run NetBSD containers from netbsd/arm64 OCI images",
        subcommands: [Create.self, Run.self]
    )

    struct CommonOptions: ParsableArguments {
        @Argument(help: "netbsd/arm64 OCI image reference")
        var image: String

        @Option(name: .long, help: "Container name")
        var name: String

        @Option(name: .long, help: "Virtual CPU count")
        var cpus: Int = 2

        @Option(name: .long, help: "Memory in MiB")
        var memory: UInt64 = 512

        @Option(name: .long, help: "Disk size in MiB; defaults from unpacked image size")
        var storage: UInt64?

        @Flag(name: [.short, .long], help: "Allocate a PTY for the main process")
        var terminal = false

        @Option(name: [.short, .long], help: "Set or replace an environment entry")
        var env: [String] = []

        @Option(name: .long, help: "Working directory inside the container")
        var cwd: String?

        @Option(name: [.short, .long], help: "OCI user, uid, user:group, or uid:gid")
        var user: String?

        @Option(name: .long, help: "Override the OCI entrypoint")
        var entrypoint: String?

        @Argument(help: "Arguments replacing the OCI Cmd; use -- before command flags")
        var command: [String] = []

        func build() async throws -> (ContainerConfiguration, Data) {
            guard cpus > 0 else { throw ValidationError("--cpus must be positive") }
            guard memory >= 200 else { throw ValidationError("--memory must be at least 200 MiB") }
            guard storage == nil || storage! >= 1024 else {
                throw ValidationError("--storage must be at least 1024 MiB")
            }
            guard env.allSatisfy({ $0.contains("=") && !$0.hasPrefix("=") }) else {
                throw ValidationError("--env values must use NAME=VALUE")
            }

            let platform = Platform(arch: "arm64", os: "netbsd")
            let fetched = try await ClientImage.fetch(
                reference: image,
                platform: platform,
                containerSystemConfig: ContainerSystemConfig()
            )
            let index = try await fetched.index()
            guard let manifestDescriptor = index.manifests.first(where: { $0.platform == platform }) else {
                throw ValidationError("image does not contain netbsd/arm64")
            }
            let manifest = try await fetched.manifest(for: platform)
            let imageDocument = try await fetched.config(for: platform)
            guard imageDocument.os == "netbsd", imageDocument.architecture == "arm64" else {
                throw ValidationError("image config must target netbsd/arm64")
            }
            if let version = imageDocument.osVersion, !version.hasPrefix("11.") {
                throw ValidationError("image requires unsupported NetBSD version \(version)")
            }
            guard manifest.layers.count == imageDocument.rootfs.diffIDs.count else {
                throw ValidationError("OCI manifest layer count does not match config DiffIDs")
            }

            let store = RemoteContentStoreClient()
            var layerSources: [OCILayerSource] = []
            for (descriptor, diffID) in zip(manifest.layers, imageDocument.rootfs.diffIDs) {
                guard let content = try await store.get(digest: descriptor.digest) else {
                    throw ValidationError("OCI layer is missing from image store: \(descriptor.digest)")
                }
                layerSources.append(OCILayerSource(descriptor: descriptor, diffID: diffID, file: content.path))
            }

            let assets = try RuntimeAssets.locate()
            let assembly = try NetBSDDiskAssembler().assemble(
                NetBSDDiskAssemblyRequest(
                    imageReference: fetched.reference,
                    manifestDigest: manifestDescriptor.digest,
                    layers: layerSources,
                    platformKit: assets.platformKit,
                    agent: assets.agent,
                    cache: try RuntimeAssets.cacheDirectory(),
                    requestedStorageBytes: storage.map { $0 * 1024 * 1024 }
                )
            )

            var configuration = ContainerConfiguration(
                id: name,
                image: fetched.description,
                process: try processConfiguration(imageDocument.config)
            )
            configuration.platform = platform
            configuration.runtimeHandler = "container-runtime-netbsd"
            configuration.networks = []
            configuration.labels = imageDocument.config?.labels ?? [:]
            configuration.stopSignal = imageDocument.config?.stopSignal
            configuration.resources.cpus = cpus
            configuration.resources.cpuOverhead = 0
            configuration.resources.memoryInBytes = memory * 1024 * 1024
            configuration.resources.storage = assembly.storageBytes

            let runtimeData = try NetBSDRuntimeData(
                diskPath: assembly.disk.path,
                diskSHA512: assembly.sha512,
                imageReference: fetched.reference,
                manifestDigest: manifestDescriptor.digest,
                platformKitDigest: assembly.platformKitDigest,
                assemblerVersion: assembly.assemblerVersion
            )
            return (configuration, try JSONEncoder().encode(runtimeData))
        }

        private func processConfiguration(_ config: ImageConfig?) throws -> ProcessConfiguration {
            var values: [String: String] = [:]
            for item in config?.env ?? [] {
                let fields = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if fields.count == 2 { values[String(fields[0])] = String(fields[1]) }
            }
            for item in env {
                let fields = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                values[String(fields[0])] = String(fields[1])
            }
            if values["PATH"] == nil { values["PATH"] = "/bin:/sbin:/usr/bin:/usr/sbin" }
            if values["HOME"] == nil { values["HOME"] = "/root" }
            if terminal, values["TERM"] == nil { values["TERM"] = "xterm-256color" }

            var arguments: [String] = []
            if let entrypoint, !entrypoint.isEmpty { arguments = [entrypoint] }
            else if let configured = config?.entrypoint, !configured.isEmpty { arguments = configured }
            if command.isEmpty {
                if entrypoint == nil, let configured = config?.cmd { arguments.append(contentsOf: configured) }
            } else {
                arguments.append(contentsOf: command)
            }
            guard let executable = arguments.first else {
                throw ValidationError("command/entrypoint not specified by image or CLI")
            }
            let selectedUser = user ?? config?.user
            return ProcessConfiguration(
                executable: executable,
                arguments: Array(arguments.dropFirst()),
                environment: values.keys.sorted().map { "\($0)=\(values[$0]!)" },
                workingDirectory: cwd ?? config?.workingDir ?? "/",
                terminal: terminal,
                user: selectedUser.map { .raw(userString: $0) } ?? .id(uid: 0, gid: 0)
            )
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create", abstract: "Create a NetBSD container from an OCI image"
        )
        @OptionGroup var options: CommonOptions

        func run() async throws {
            let (configuration, runtimeData) = try await options.build()
            try await ContainerClient().create(configuration: configuration, runtimeData: runtimeData)
            print(configuration.id)
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run", abstract: "Create, boot, and run a NetBSD OCI container"
        )
        @OptionGroup var options: CommonOptions

        @Flag(name: .long, help: "Delete container state after exit")
        var remove = false

        func run() async throws {
            let (configuration, runtimeData) = try await options.build()
            let client = ContainerClient()
            try await client.create(
                configuration: configuration,
                options: ContainerCreateOptions(autoRemove: remove),
                runtimeData: runtimeData
            )
            do {
                let process = try await client.bootstrap(
                    id: configuration.id,
                    stdio: [FileHandle.standardInput, FileHandle.standardOutput, FileHandle.standardError]
                )
                try await process.start()
                let status = try await process.wait()
                if remove { try? await client.delete(id: configuration.id, force: true) }
                Darwin.exit(status)
            } catch {
                try? await client.stop(id: configuration.id)
                if remove { try? await client.delete(id: configuration.id, force: true) }
                throw error
            }
        }
    }
}

private struct RuntimeAssets {
    let platformKit: NetBSDPlatformKit
    let agent: URL

    static func locate() throws -> RuntimeAssets {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["NETBSD_VZ_PLATFORM_KIT"] {
            return RuntimeAssets(
                platformKit: try NetBSDPlatformKit(root: URL(fileURLWithPath: root)),
                agent: try locateAgent(startingAt: URL(fileURLWithPath: root))
            )
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            for candidate in [
                directory.appendingPathComponent("platform-kit"),
                directory.appendingPathComponent(".build/platform-kit/root"),
                directory.appendingPathComponent("../container-runtime-netbsd/platform-kit").standardizedFileURL,
            ] where FileManager.default.fileExists(atPath: candidate.path) {
                return RuntimeAssets(
                    platformKit: try NetBSDPlatformKit(root: candidate),
                    agent: try locateAgent(startingAt: directory)
                )
            }
            directory.deleteLastPathComponent()
        }
        throw ValidationError(
            "NetBSD platform kit not found; install it or set NETBSD_VZ_PLATFORM_KIT to its absolute directory"
        )
    }

    static func cacheDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CONTAINER_RUNTIME_NETBSD_CACHE"] {
            guard (override as NSString).isAbsolutePath else {
                throw ValidationError("CONTAINER_RUNTIME_NETBSD_CACHE must be absolute")
            }
            return URL(fileURLWithPath: override)
        }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw ValidationError("cannot locate Application Support directory")
        }
        return applicationSupport
            .appendingPathComponent("container-runtime-netbsd/cache/v1", isDirectory: true)
    }

    private static func locateAgent(startingAt start: URL) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CONTAINER_RUNTIME_NETBSD_AGENT"] {
            let value = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: value.path) else {
                throw ValidationError("CONTAINER_RUNTIME_NETBSD_AGENT is not executable")
            }
            return value
        }
        var directory = start.standardizedFileURL
        for _ in 0..<8 {
            for relative in [
                "netbsd-vz-agent", ".build/out/netbsd-vz-agent", "bin/netbsd-vz-agent",
                "../container-runtime-netbsd/bin/netbsd-vz-agent",
            ] {
                let candidate = directory.appendingPathComponent(relative)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            directory.deleteLastPathComponent()
        }
        throw ValidationError(
            "NetBSD guest agent not found; install it or set CONTAINER_RUNTIME_NETBSD_AGENT"
        )
    }
}
