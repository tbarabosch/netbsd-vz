import Darwin
import Foundation
@preconcurrency import Virtualization

private enum RunnerError: Error, CustomStringConvertible {
    case usage(String)
    case invalidDisk(String)
    case invalidEFIState(String)
    case smokeFailed(String)
    case stoppedBeforeTimeout(String)
    case systemCall(String, Int32)

    var description: String {
        switch self {
        case .usage(let message), .invalidDisk(let message), .invalidEFIState(let message):
            return message
        case .smokeFailed(let reason):
            return "smoke test failed: \(reason)"
        case .stoppedBeforeTimeout(let state):
            return "the virtual machine entered state \(state) before the run timeout"
        case .systemCall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

private enum PersistenceProbe: Equatable {
    case none
    case write
    case read
}

private struct Options {
    let timeoutSeconds: Int
    let disk: URL
    let efiState: URL
    let persistenceProbe: PersistenceProbe
    let smoke: Bool
    let network: Bool

    private static let usage =
        "usage: netbsd-vz-runner --disk RAW --efi-state DIR "
        + "[--timeout SECONDS] [--network] [--smoke] "
        + "[--persistence-write|--persistence-read]"

    static func parse(_ arguments: [String]) throws -> Options {
        var timeout: Int?
        var diskPath: String?
        var efiStatePath: String?
        var persistenceProbe = PersistenceProbe.none
        var smoke = false
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
            case "--persistence-write":
                guard persistenceProbe == .none else {
                    throw RunnerError.usage("only one persistence probe may be selected")
                }
                persistenceProbe = .write
            case "--persistence-read":
                guard persistenceProbe == .none else {
                    throw RunnerError.usage("only one persistence probe may be selected")
                }
                persistenceProbe = .read
            case "--smoke":
                smoke = true
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
        if persistenceProbe != .none, !smoke {
            throw RunnerError.usage("persistence probes require --smoke")
        }
        return Options(
            timeoutSeconds: timeout ?? 120,
            disk: URL(fileURLWithPath: diskPath).standardizedFileURL,
            efiState: URL(
                fileURLWithPath: efiStatePath,
                isDirectory: true
            ).standardizedFileURL,
            persistenceProbe: persistenceProbe,
            smoke: smoke,
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

private enum RunResult: Equatable {
    case timedOut
    case smokeSucceeded
}

private struct SmokeEvidence {
    var virtioNetwork = false
    var cleanUnmount = false
    var shutdownHooksDone = false
    var acpiFDT = false
    var acpi = false
    var gicV3 = false
    var genericTimer = false
    var acpiPCI = false
    var virtioConsole = false
    var virtioStorage = false
    var virtioEntropy = false
    var namedRoot = false

    mutating func observe(_ text: String) {
        virtioNetwork = virtioNetwork
            || (text.contains("] vioif") && text.contains(" at virtio"))
        cleanUnmount = cleanUnmount
            || (text.contains("unmounted /dev/dk") && text.contains(" on / type ffs"))
        shutdownHooksDone = shutdownHooksDone || text.contains("Done running shutdown hooks.")
        acpiFDT = acpiFDT || text.contains("acpifdt0 at ")
        acpi = acpi || (text.contains("acpi0 at acpifdt") || text.contains("ACPI:"))
        gicV3 = gicV3
            || (text.contains("gicvthree") && text.contains(" at acpi"))
        genericTimer = genericTimer
            || (text.contains("gtmr") && text.contains(" at acpi"))
        acpiPCI = acpiPCI
            || (text.contains("acpipchb") && text.contains(" at acpi"))
        virtioConsole = virtioConsole
            || (text.contains("viocon") && text.contains(" at virtio"))
        virtioStorage = virtioStorage
            || (text.contains("] ld") && text.contains(" at virtio"))
        virtioEntropy = virtioEntropy
            || (text.contains("viornd") && text.contains(" at virtio"))
        namedRoot = namedRoot
            || (text.contains("\"netbsd-root\"") && text.contains("type: ffs"))
    }

    func networkError(expected: Bool) -> String? {
        if expected, !virtioNetwork { return "vioif did not attach" }
        if !expected, virtioNetwork { return "vioif attached during offline smoke" }
        return nil
    }

    func efiPlatformError() -> String? {
        let requirements: [(Bool, String)] = [
            (acpiFDT, "acpifdt did not attach"),
            (acpi, "ACPI did not attach"),
            (gicV3, "GICv3 did not attach through ACPI"),
            (genericTimer, "generic timer did not attach through ACPI"),
            (acpiPCI, "ACPI PCI host bridge did not attach"),
            (virtioConsole, "viocon did not attach"),
            (virtioStorage, "Virtio block storage did not attach"),
            (virtioEntropy, "Virtio entropy did not attach"),
            (namedRoot, "netbsd-root GPT wedge was not discovered"),
        ]
        return requirements.first(where: { !$0.0 })?.1
    }
}

private enum SmokeStage: Equatable {
    case waitingForLogin
    case waitingForRootPrompt
    case waitingForUserspaceMarker
    case waitingForNetworkMarker
    case waitingForShutdown
}

private let networkSmokeCommand =
    "/sbin/dmesg | /usr/bin/grep 'vioif.* at virtio'\n"
    + "iface=; "
    + "for candidate in $(/sbin/ifconfig -l); do "
    + "case \"$candidate\" in vioif*) iface=$candidate; break;; esac; done\n"
    + "/sbin/ifconfig \"$iface\"\n"
    + "/sbin/route -n get default\n"
    + "status=$(/sbin/ifconfig \"$iface\" | "
    + "/usr/bin/awk '$1 == \"status:\" && $2 == \"active\" { print $2; exit }')\n"
    + "addr=$(/sbin/ifconfig \"$iface\" inet | "
    + "/usr/bin/awk '$1 == \"inet\" && $2 !~ /^169[.]254[.]/ { print $2; exit }')\n"
    + "gateway=$(/sbin/route -n -s get default 2>/dev/null)\n"
    + "public=8.8.8.8\n"
    + "printf 'NETBSD_VZ_NETWORK_IFACE_%s\\n' \"$iface\"\n"
    + "printf 'NETBSD_VZ_NETWORK_ADDR_%s\\n' \"$addr\"\n"
    + "printf 'NETBSD_VZ_NETWORK_GATEWAY_%s\\n' \"$gateway\"\n"
    + "printf 'NETBSD_VZ_NETWORK_PUBLIC_%s\\n' \"$public\"\n"
    + "if [ -z \"$iface\" ]; then "
    + "printf 'NETBSD_VZ_NETWORK_FAIL_%s\\n' NO_INTERFACE; "
    + "elif [ \"$status\" != active ]; then "
    + "printf 'NETBSD_VZ_NETWORK_FAIL_%s\\n' NO_CARRIER; "
    + "elif [ -z \"$addr\" ]; then "
    + "printf 'NETBSD_VZ_NETWORK_FAIL_%s\\n' NO_IPV4; "
    + "elif [ -z \"$gateway\" ]; then "
    + "printf 'NETBSD_VZ_NETWORK_FAIL_%s\\n' NO_GATEWAY; "
    + "elif ! /sbin/ping -n -c 1 -w 5 \"$gateway\"; then "
    + "printf 'NETBSD_VZ_NETWORK_FAIL_%s\\n' GATEWAY_UNREACHABLE; "
    + "elif /sbin/ping -n -c 1 -w 5 \"$public\"; then "
    + "printf 'NETBSD_VZ_NETWORK_%s\\n' OK; "
    + "else printf 'NETBSD_VZ_NETWORK_FAIL_%s\\n' PUBLIC_UNREACHABLE; fi\n"

private func outputLine(startingWith prefix: String, in text: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline) {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix(prefix) {
            return normalized
        }
    }
    return nil
}

private func runUntilTimeout(
    from handle: FileHandle,
    inputHandle: FileHandle?,
    transcriptHandle: FileHandle?,
    smoke: Bool,
    network: Bool,
    persistenceProbe: PersistenceProbe,
    vm: VZVirtualMachine,
    queue: DispatchQueue,
    timeoutSeconds: Int
) throws -> RunResult {
    let descriptor = handle.fileDescriptor
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    var scanBuffer = ""
    var smokeStage = SmokeStage.waitingForLogin
    var evidence = SmokeEvidence()

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
                let data = Data(bytes[0..<count])
                try FileHandle.standardOutput.write(contentsOf: data)
                try transcriptHandle?.write(contentsOf: data)
                if smoke {
                    scanBuffer += String(decoding: data, as: UTF8.self)
                    if scanBuffer.utf8.count > 256 * 1024 {
                        scanBuffer = String(scanBuffer.suffix(128 * 1024))
                    }
                    evidence.observe(scanBuffer)

                    let fatalPatterns = [
                        "cannot mount root",
                        "exec /sbin/init: error",
                        "init: not found",
                    ]
                    if let fatal = fatalPatterns.first(where: { scanBuffer.contains($0) }) {
                        throw RunnerError.smokeFailed("guest reported \(fatal)")
                    }
                    let panicked = scanBuffer.split(separator: "\n").contains { line in
                        line.hasPrefix("panic:") || line.contains("] panic:")
                    }
                    if panicked {
                        throw RunnerError.smokeFailed("guest reported a kernel panic")
                    }

                    switch smokeStage {
                    case .waitingForLogin where scanBuffer.contains("login:"):
                        guard let inputHandle else {
                            throw RunnerError.smokeFailed("serial input pipe is unavailable")
                        }
                        try inputHandle.write(contentsOf: Data("root\n".utf8))
                        smokeStage = .waitingForRootPrompt
                        scanBuffer = ""
                    case .waitingForRootPrompt where scanBuffer.contains("# "):
                        guard let inputHandle else {
                            throw RunnerError.smokeFailed("serial input pipe is unavailable")
                        }
                        var command = "/sbin/dmesg\n"
                        switch persistenceProbe {
                        case .none:
                            break
                        case .write:
                            command += "printf 'NETBSD_VZ_PERSISTENCE_%s\\n' OK "
                                + "> /var/db/netbsd-vz-persistence\n"
                                + "/bin/sync\n"
                                + "printf 'NETBSD_VZ_PERSISTENCE_WRITE_%s\\n' OK\n"
                        case .read:
                            command += "if /usr/bin/grep -q NETBSD_VZ_PERSISTENCE_OK "
                                + "/var/db/netbsd-vz-persistence; then "
                                + "printf 'NETBSD_VZ_PERSISTENCE_READ_%s\\n' OK; "
                                + "else printf 'NETBSD_VZ_PERSISTENCE_READ_%s\\n' FAIL; fi\n"
                        }
                        command += "printf 'NETBSD_VZ_USERSPACE_%s\\n' OK\n"
                        try inputHandle.write(contentsOf: Data(command.utf8))
                        smokeStage = .waitingForUserspaceMarker
                        scanBuffer = ""
                    case .waitingForUserspaceMarker
                        where scanBuffer.contains("NETBSD_VZ_USERSPACE_OK"):
                        if scanBuffer.contains("NETBSD_VZ_PERSISTENCE_READ_FAIL") {
                            throw RunnerError.smokeFailed("persistence marker was not recovered")
                        }
                        if persistenceProbe == .write,
                            !scanBuffer.contains("NETBSD_VZ_PERSISTENCE_WRITE_OK") {
                            throw RunnerError.smokeFailed("persistence marker was not written")
                        }
                        if persistenceProbe == .read,
                            !scanBuffer.contains("NETBSD_VZ_PERSISTENCE_READ_OK") {
                            throw RunnerError.smokeFailed("persistence marker was not read")
                        }
                        if let error = evidence.efiPlatformError() {
                            throw RunnerError.smokeFailed(error)
                        }
                        if let error = evidence.networkError(expected: network) {
                            throw RunnerError.smokeFailed(error)
                        }
                        guard let inputHandle else {
                            throw RunnerError.smokeFailed("serial input pipe is unavailable")
                        }
                        if network {
                            try inputHandle.write(contentsOf: Data(networkSmokeCommand.utf8))
                            smokeStage = .waitingForNetworkMarker
                        } else {
                            try inputHandle.write(
                                contentsOf: Data("/sbin/shutdown -p now\n".utf8)
                            )
                            smokeStage = .waitingForShutdown
                        }
                        scanBuffer = ""
                    case .waitingForNetworkMarker:
                        if let failure = outputLine(
                            startingWith: "NETBSD_VZ_NETWORK_FAIL_",
                            in: scanBuffer
                        ) {
                            throw RunnerError.smokeFailed(
                                "network probe reported \(failure)"
                            )
                        }
                        if scanBuffer.contains("NETBSD_VZ_NETWORK_OK") {
                            guard let inputHandle else {
                                throw RunnerError.smokeFailed(
                                    "serial input pipe is unavailable"
                                )
                            }
                            try inputHandle.write(
                                contentsOf: Data("/sbin/shutdown -p now\n".utf8)
                            )
                            smokeStage = .waitingForShutdown
                            scanBuffer = ""
                        }
                    default:
                        break
                    }
                }
            }
        }

        let state = queue.sync { vm.state }
        if smoke, smokeStage == .waitingForShutdown, state == .stopped {
            guard evidence.cleanUnmount || evidence.shutdownHooksDone else {
                throw RunnerError.smokeFailed(
                    "guest stopped before shutdown completion was observed"
                )
            }
            return .smokeSucceeded
        }
        if smoke, smokeStage == .waitingForShutdown, state == .stopping {
            continue
        }
        if state != .running {
            if smoke {
                throw RunnerError.smokeFailed(
                    "virtual machine entered state \(state) before guest poweroff"
                )
            }
            throw RunnerError.stoppedBeforeTimeout(String(describing: state))
        }
    }

    let state = queue.sync { vm.state }
    if smoke, smokeStage == .waitingForShutdown, state == .stopped {
        guard evidence.cleanUnmount || evidence.shutdownHooksDone else {
            throw RunnerError.smokeFailed(
                "guest stopped before shutdown completion was observed"
            )
        }
        return .smokeSucceeded
    }
    if state != .running {
        if smoke {
            throw RunnerError.smokeFailed(
                "virtual machine entered state \(state) before guest poweroff completed"
            )
        }
        throw RunnerError.stoppedBeforeTimeout(String(describing: state))
    }
    if smoke {
        let detail: String
        switch smokeStage {
        case .waitingForLogin:
            detail = "login prompt did not appear"
        case .waitingForRootPrompt:
            detail = "root prompt did not appear"
        case .waitingForUserspaceMarker:
            detail = "userspace marker did not appear"
        case .waitingForNetworkMarker:
            detail = "network proof did not complete"
        case .waitingForShutdown:
            detail = "guest did not power off"
        }
        throw RunnerError.smokeFailed("\(detail) before the \(timeoutSeconds)s timeout")
    }
    return .timedOut
}

private func makeTranscriptHandle() throws -> FileHandle? {
    guard let path = ProcessInfo.processInfo.environment["NETBSD_VZ_TRANSCRIPT"],
        !path.isEmpty
    else {
        return nil
    }
    guard FileManager.default.createFile(atPath: path, contents: nil) else {
        throw RunnerError.smokeFailed("cannot create console transcript: \(path)")
    }
    return try FileHandle(forWritingTo: URL(fileURLWithPath: path))
}

@main
private struct NetBSDVZRunner {
    static func main() async {
        do {
            let options = try Options.parse(CommandLine.arguments)
            try validateDisk(options.disk)
            let efiState = try loadOrCreateEFIState(options.efiState)

            let outputPipe = Pipe()
            let inputPipe = options.smoke ? Pipe() : nil
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: inputPipe?.fileHandleForReading ?? FileHandle.standardInput,
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

            let queue = DispatchQueue(label: "org.netbsd.vz-probe.vm")
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
            let transcriptHandle = try makeTranscriptHandle()
            defer { try? transcriptHandle?.close() }
            try await start(vm, on: queue)

            let result: RunResult
            do {
                result = try runUntilTimeout(
                    from: outputPipe.fileHandleForReading,
                    inputHandle: inputPipe?.fileHandleForWriting,
                    transcriptHandle: transcriptHandle,
                    smoke: options.smoke,
                    network: options.network,
                    persistenceProbe: options.persistenceProbe,
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
            case .timedOut:
                FileHandle.standardError.write(
                    Data("\nReached \(options.timeoutSeconds)s run timeout; stopping VM.\n".utf8)
                )
            case .smokeSucceeded:
                let markers = options.network
                    ? "NETBSD_VZ_USERSPACE_OK and NETBSD_VZ_NETWORK_OK"
                    : "NETBSD_VZ_USERSPACE_OK"
                FileHandle.standardError.write(
                    Data(
                        "\nObserved \(markers) and guest poweroff; smoke test passed.\n".utf8
                    )
                )
            }
            if result == .timedOut {
                try await stop(vm, on: queue)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
