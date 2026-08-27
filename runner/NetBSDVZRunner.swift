import Darwin
import Foundation
@preconcurrency import Virtualization

private enum RunnerError: Error, CustomStringConvertible {
    case usage(String)
    case invalidDisk(String)
    case invalidEFIState(String)
    case unexpectedState(String)
    case systemCall(String, Int32)

    var description: String {
        switch self {
        case .usage(let message), .invalidDisk(let message), .invalidEFIState(let message):
            return message
        case .unexpectedState(let state):
            return "the virtual machine entered unexpected state \(state)"
        case .systemCall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

private struct Options {
    let timeoutSeconds: Int
    let disk: URL
    let efiState: URL
    let network: Bool

    private static let usage =
        "usage: netbsd-vz-runner --disk RAW --efi-state DIR "
        + "[--timeout SECONDS] [--network]"

    static func parse(_ arguments: [String]) throws -> Options {
        var timeout: Int?
        var diskPath: String?
        var efiStatePath: String?
        var network = false
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--timeout":
                index += 1
                guard index < arguments.count,
                    let parsed = Int(arguments[index]), parsed > 0
                else {
                    throw RunnerError.usage("--timeout requires a positive number of seconds")
                }
                timeout = parsed
            case "--disk":
                index += 1
                guard index < arguments.count else {
                    throw RunnerError.usage("--disk requires a path")
                }
                diskPath = arguments[index]
            case "--efi-state":
                index += 1
                guard index < arguments.count else {
                    throw RunnerError.usage("--efi-state requires a directory")
                }
                efiStatePath = arguments[index]
            case "--network":
                network = true
            case "-h", "--help":
                throw RunnerError.usage(usage)
            default:
                throw RunnerError.usage("unknown option: \(arguments[index])")
            }
            index += 1
        }

        guard let diskPath else {
            throw RunnerError.usage("--disk requires a RAW EFI disk")
        }
        guard let efiStatePath else {
            throw RunnerError.usage("--efi-state requires a directory")
        }
        return Options(
            timeoutSeconds: timeout ?? 120,
            disk: URL(fileURLWithPath: diskPath).standardizedFileURL,
            efiState: URL(
                fileURLWithPath: efiStatePath,
                isDirectory: true
            ).standardizedFileURL,
            network: network
        )
    }
}

private func validateDisk(_ url: URL) throws {
    let attributes: [FileAttributeKey: Any]
    do {
        attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
        throw RunnerError.invalidDisk("cannot inspect disk image \(url.path): \(error)")
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw RunnerError.invalidDisk("disk image is not a regular file: \(url.path)")
    }
    guard let fileSize = attributes[.size] as? NSNumber else {
        throw RunnerError.invalidDisk("cannot determine disk image size: \(url.path)")
    }
    guard fileSize.uint64Value > 0 else {
        throw RunnerError.invalidDisk("disk image is empty: \(url.path)")
    }
    guard fileSize.uint64Value.isMultiple(of: 512) else {
        throw RunnerError.invalidDisk("disk image size is not 512-byte aligned: \(url.path)")
    }
}

private struct EFIState {
    let machineIdentifier: VZGenericMachineIdentifier
    let variableStore: VZEFIVariableStore
}

private func loadOrCreateEFIState(_ directory: URL) throws -> EFIState {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        throw RunnerError.invalidEFIState(
            "EFI state path is not an existing directory: \(directory.path)"
        )
    }

    let identifierURL = directory.appendingPathComponent("machine-identifier.bin")
    let variableStoreURL = directory.appendingPathComponent("variable-store.bin")
    let machineIdentifier: VZGenericMachineIdentifier
    if FileManager.default.fileExists(atPath: identifierURL.path) {
        let data = try Data(contentsOf: identifierURL)
        guard let savedIdentifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
            throw RunnerError.invalidEFIState(
                "saved machine identifier is invalid: \(identifierURL.path)"
            )
        }
        machineIdentifier = savedIdentifier
    } else {
        let newIdentifier = VZGenericMachineIdentifier()
        try newIdentifier.dataRepresentation.write(to: identifierURL, options: .atomic)
        machineIdentifier = newIdentifier
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
    return EFIState(machineIdentifier: machineIdentifier, variableStore: variableStore)
}

private func start(_ vm: VZVirtualMachine, on queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { continuation in
        queue.sync {
            vm.start { result in
                continuation.resume(with: result)
            }
        }
    }
}

private func stop(_ vm: VZVirtualMachine, on queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        queue.sync {
            vm.stop { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private enum RunResult {
    case stopped
    case timedOut
}

private func runUntilStoppedOrTimeout(
    from handle: FileHandle,
    vm: VZVirtualMachine,
    queue: DispatchQueue,
    timeoutSeconds: Int
) throws -> RunResult {
    let descriptor = handle.fileDescriptor
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

    while Date() < deadline {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&pollDescriptor, 1, 100)
        if result < 0 {
            if errno == EINTR { continue }
            throw RunnerError.systemCall("poll", errno)
        }
        if result > 0, pollDescriptor.revents & Int16(POLLIN) != 0 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw RunnerError.systemCall("read", errno)
            }
            if count > 0 {
                try FileHandle.standardOutput.write(contentsOf: Data(bytes[0..<count]))
            }
        }

        let state = queue.sync { vm.state }
        if state == .stopped {
            return .stopped
        }
        if state == .stopping {
            continue
        }
        if state != .running {
            throw RunnerError.unexpectedState(String(describing: state))
        }
    }

    let state = queue.sync { vm.state }
    if state == .stopped || state == .stopping {
        return .stopped
    }
    guard state == .running else {
        throw RunnerError.unexpectedState(String(describing: state))
    }
    return .timedOut
}

@main
private struct NetBSDVZRunner {
    static func main() async {
        do {
            let options = try Options.parse(CommandLine.arguments)
            try validateDisk(options.disk)
            let efiState = try loadOrCreateEFIState(options.efiState)

            let outputPipe = Pipe()
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle.standardInput,
                fileHandleForWriting: outputPipe.fileHandleForWriting
            )

            let platform = VZGenericPlatformConfiguration()
            platform.machineIdentifier = efiState.machineIdentifier
            let loader = VZEFIBootLoader()
            loader.variableStore = efiState.variableStore

            let configuration = VZVirtualMachineConfiguration()
            configuration.platform = platform
            configuration.bootLoader = loader
            configuration.cpuCount = VZVirtualMachineConfiguration.minimumAllowedCPUCount
            configuration.memorySize = max(
                VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                512 * 1024 * 1024
            )
            configuration.serialPorts = [serial]
            configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(
                    widthInPixels: 1280,
                    heightInPixels: 720
                )
            ]
            configuration.graphicsDevices = [graphics]
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: options.disk,
                readOnly: false,
                cachingMode: .automatic,
                synchronizationMode: .full
            )
            let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
            blockDevice.blockDeviceIdentifier = "netbsd-vz-root"
            configuration.storageDevices = [blockDevice]
            var networkMAC: VZMACAddress?
            if options.network {
                let networkDevice = VZVirtioNetworkDeviceConfiguration()
                let mac = VZMACAddress.randomLocallyAdministered()
                networkDevice.macAddress = mac
                networkDevice.attachment = VZNATNetworkDeviceAttachment()
                configuration.networkDevices = [networkDevice]
                networkMAC = mac
            }
            try configuration.validate()

            let queue = DispatchQueue(label: "org.netbsd.vz-poc.vm")
            let vm = VZVirtualMachine(configuration: configuration, queue: queue)

            FileHandle.standardError.write(
                Data("Booting NetBSD through generic EFI/ACPI...\n".utf8)
            )
            FileHandle.standardError.write(
                Data("Using EFI state \(options.efiState.path)...\n".utf8)
            )
            FileHandle.standardError.write(
                Data("Attaching disk \(options.disk.path)...\n".utf8)
            )
            if let networkMAC {
                FileHandle.standardError.write(
                    Data(
                        "Attaching Virtio NAT network with MAC \(networkMAC.string)...\n".utf8
                    )
                )
            }
            try await start(vm, on: queue)

            let result: RunResult
            do {
                result = try runUntilStoppedOrTimeout(
                    from: outputPipe.fileHandleForReading,
                    vm: vm,
                    queue: queue,
                    timeoutSeconds: options.timeoutSeconds
                )
            } catch {
                if queue.sync(execute: { vm.state }) == .running {
                    try? await stop(vm, on: queue)
                }
                throw error
            }

            switch result {
            case .stopped:
                FileHandle.standardError.write(Data("\nVirtual machine stopped.\n".utf8))
            case .timedOut:
                FileHandle.standardError.write(
                    Data("\nReached \(options.timeoutSeconds)s run timeout; stopping VM.\n".utf8)
                )
                try await stop(vm, on: queue)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
