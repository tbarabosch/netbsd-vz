import Darwin
import Foundation
import NetBSDAgentProtocol
@preconcurrency import Virtualization

public enum RuntimeMachineState: String, Codable, Sendable {
    case created
    case booted
    case running
    case stopping
    case stopped
}

public final class NetBSDVirtualMachine: @unchecked Sendable {
    public let root: URL
    public let disk: URL
    public let bootLog: URL
    public let agent: AgentConnection

    private let queue: DispatchQueue
    private let vm: VZVirtualMachine
    private let consoleOutput: FileHandle
    private let consoleInput: FileHandle
    private let hostToGuest: Pipe
    private let guestToHost: Pipe

    public init(
        root: URL,
        runtimeData: NetBSDRuntimeData,
        cpuCount: Int,
        memorySize: UInt64
    ) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)

        let baseDisk = try runtimeData.validatedDisk()
        let resources = self.root.appendingPathComponent("netbsd-runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        disk = resources.appendingPathComponent("root.raw")
        if !FileManager.default.fileExists(atPath: disk.path) {
            guard clonefile(baseDisk.path, disk.path, 0) == 0 else {
                throw NetBSDRuntimeError.invalidConfiguration(
                    "could not create APFS CoW clone of \(baseDisk.path): \(String(cString: strerror(errno)))"
                )
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: disk.path)
        }

        let efi = try Self.loadOrCreateEFIState(in: resources.appendingPathComponent("efi", isDirectory: true))
        bootLog = resources.appendingPathComponent("boot.log")
        if !FileManager.default.fileExists(atPath: bootLog.path) {
            FileManager.default.createFile(atPath: bootLog.path, contents: nil)
        }
        consoleOutput = try FileHandle(forWritingTo: bootLog)
        try consoleOutput.seekToEnd()
        consoleInput = FileHandle(forReadingAtPath: "/dev/null")!

        hostToGuest = Pipe()
        guestToHost = Pipe()
        agent = AgentConnection(
            input: guestToHost.fileHandleForReading,
            output: hostToGuest.fileHandleForWriting
        )

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: consoleInput,
            fileHandleForWriting: consoleOutput
        )
        let control = VZVirtioConsoleDeviceSerialPortConfiguration()
        control.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: hostToGuest.fileHandleForReading,
            fileHandleForWriting: guestToHost.fileHandleForWriting
        )

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = efi.machineIdentifier
        let loader = VZEFIBootLoader()
        loader.variableStore = efi.variableStore

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = loader
        configuration.cpuCount = max(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            min(cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        )
        configuration.memorySize = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        )
        configuration.serialPorts = [console, control]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)
        ]
        configuration.graphicsDevices = [graphics]
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: disk,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        let storage = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        storage.blockDeviceIdentifier = "netbsd-vz-root"
        configuration.storageDevices = [storage]
        try configuration.validate()

        queue = DispatchQueue(label: "org.netbsd.container-runtime.vm.\(UUID().uuidString)")
        vm = VZVirtualMachine(configuration: configuration, queue: queue)
    }

    deinit {
        if queue.sync(execute: { vm.state }) == .running {
            queue.sync { vm.stop(completionHandler: { _ in }) }
        }
        try? consoleOutput.close()
    }

    public func boot(timeout: Duration = .seconds(120)) async throws -> AgentHello {
        try await startVM()
        do {
            return try await agent.handshake(timeout: timeout)
        } catch {
            try? await forceStop()
            throw error
        }
    }

    public func forceStop() async throws {
        let current = queue.sync { vm.state }
        guard current == .running || current == .paused || current == .pausing else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.sync {
                vm.stop { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }

    public var isRunning: Bool {
        queue.sync { vm.state == .running }
    }

    private func startVM() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.sync {
                vm.start { result in continuation.resume(with: result) }
            }
        }
    }

    private struct EFIState {
        let machineIdentifier: VZGenericMachineIdentifier
        let variableStore: VZEFIVariableStore
    }

    private static func loadOrCreateEFIState(in directory: URL) throws -> EFIState {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifierURL = directory.appendingPathComponent("machine-identifier.bin")
        let variableStoreURL = directory.appendingPathComponent("variable-store.bin")
        let identifier: VZGenericMachineIdentifier
        if FileManager.default.fileExists(atPath: identifierURL.path) {
            let data = try Data(contentsOf: identifierURL)
            guard let stored = VZGenericMachineIdentifier(dataRepresentation: data) else {
                throw NetBSDRuntimeError.invalidConfiguration("invalid persistent VZ machine identifier")
            }
            identifier = stored
        } else {
            identifier = VZGenericMachineIdentifier()
            try identifier.dataRepresentation.write(to: identifierURL, options: .atomic)
        }
        let variableStore: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: variableStoreURL.path) {
            variableStore = VZEFIVariableStore(url: variableStoreURL)
        } else {
            variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: variableStoreURL,
                options: []
            )
        }
        return EFIState(machineIdentifier: identifier, variableStore: variableStore)
    }
}
