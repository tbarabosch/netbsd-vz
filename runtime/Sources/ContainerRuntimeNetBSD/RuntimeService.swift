import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Darwin
import Foundation
import Logging
import NetBSDAgentProtocol
import NetBSDRuntimeCore
import XPC

actor RuntimeService {
    enum State: Sendable {
        case created, booted, running, stopping, stopped, shuttingDown
    }

    struct RuntimeConfigurationEnvelope: Decodable {
        let runtimeData: Data?
        let containerConfiguration: ContainerConfiguration?
    }

    struct ProcessRecord: Sendable {
        let numericID: UInt64
        let configuration: ProcessConfiguration
        let io: ProcessIO
        var started: Bool
    }

    private let root: URL
    private let endpointConnection: xpc_connection_t
    private let log: Logger
    private var state: State = .created
    private var machine: NetBSDVirtualMachine?
    private var configuration: ContainerConfiguration?
    private var processes: [String: ProcessRecord] = [:]
    private var nextProcessID: UInt64 = 1
    private var logHandle: FileHandle?

    init(root: URL, endpointConnection: xpc_connection_t, log: Logger) {
        self.root = root
        self.endpointConnection = endpointConnection
        self.log = log
    }

    @Sendable func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        let reply = message.reply()
        reply.set(
            key: RuntimeKeys.runtimeServiceEndpoint.rawValue,
            value: xpc_endpoint_create(endpointConnection)
        )
        return reply
    }

    @Sendable func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        guard state == .created || state == .stopped else {
            throw runtimeError(.invalidState, "bootstrap requires a stopped runtime")
        }
        let runtimeConfigurationURL = root.appendingPathComponent("runtime-configuration.json")
        let envelope = try JSONDecoder().decode(
            RuntimeConfigurationEnvelope.self,
            from: Data(contentsOf: runtimeConfigurationURL)
        )
        guard let opaque = envelope.runtimeData else {
            throw runtimeError(.invalidArgument, "NetBSDRuntimeData is missing")
        }
        guard let config = envelope.containerConfiguration else {
            throw runtimeError(.invalidArgument, "container configuration is missing")
        }
        try validateV1(config)
        let runtimeData = try JSONDecoder().decode(NetBSDRuntimeData.self, from: opaque)
        guard NetBSDRuntimeData.supportedSchemaVersions.contains(runtimeData.schemaVersion) else {
            throw runtimeError(.unsupported, "unsupported NetBSDRuntimeData schema \(runtimeData.schemaVersion)")
        }
        if let infos = message.dataNoCopy(key: RuntimeKeys.networkBootstrapInfos.rawValue),
            let json = try? JSONSerialization.jsonObject(with: infos) as? [Any], !json.isEmpty
        {
            throw unsupported("network bootstrap")
        }

        let bundle = ContainerResource.Bundle(path: root)
        try bundle.set(configuration: config)
        let stdioLog = bundle.containerLog
        FileManager.default.createFile(atPath: stdioLog.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: stdioLog)
        try logHandle?.truncate(atOffset: 0)

        let vm = try NetBSDVirtualMachine(
            root: root,
            runtimeData: runtimeData,
            cpuCount: config.resources.cpus,
            memorySize: config.resources.memoryInBytes
        )
        let hello = try await vm.boot()
        log.info("NetBSD agent ready", metadata: ["build": "\(hello.build ?? "unknown")"])
        machine = vm
        configuration = config
        processes.removeAll()
        nextProcessID = 1

        var initConfiguration = try convert(config.initProcess)
        let dynamicEnvironment = try decodeDynamicEnvironment(message)
        initConfiguration = mergeDynamicEnvironment(dynamicEnvironment, into: initConfiguration)
        let io = processIO(from: message, terminal: config.initProcess.terminal)
        try await createAgentProcess(id: config.id, configuration: initConfiguration, io: io)
        state = .booted
        return message.reply()
    }

    @Sendable func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        guard state == .booted || state == .running else {
            throw runtimeError(.invalidState, "process creation requires a booted runtime")
        }
        let id = try message.requiredString(RuntimeKeys.id.rawValue)
        guard processes[id] == nil else { throw runtimeError(.exists, "process \(id) already exists") }
        let processConfig = try message.decode(ProcessConfiguration.self, key: RuntimeKeys.processConfig.rawValue)
        let converted = try convert(processConfig)
        try await createAgentProcess(
            id: id,
            configuration: converted,
            io: processIO(from: message, terminal: processConfig.terminal)
        )
        return message.reply()
    }

    @Sendable func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.requiredString(RuntimeKeys.id.rawValue)
        guard var process = processes[id], !process.started else {
            throw runtimeError(.invalidState, "process \(id) is missing or already started")
        }
        guard let agent = machine?.agent else { throw runtimeError(.invalidState, "VM is not booted") }
        let response = try await agent.request(
            AgentRequest(operation: .start), processID: process.numericID, timeout: .seconds(30)
        )
        guard response.ok else { throw runtimeError(.internalError, response.message ?? "agent start failed") }
        process.started = true
        processes[id] = process
        await agent.startStdinPump(processID: process.numericID)
        if id == configuration?.id { state = .running }
        return message.reply()
    }

    @Sendable func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.requiredString(RuntimeKeys.id.rawValue)
        guard let process = processes[id], process.started, let agent = machine?.agent else {
            throw runtimeError(.invalidState, "process \(id) is not running")
        }
        let response = try await agent.request(AgentRequest(operation: .wait), processID: process.numericID)
        let code = response.exitCode ?? 255
        let reply = message.reply()
        reply.set(key: RuntimeKeys.exitCode.rawValue, value: Int64(code))
        reply.set(key: RuntimeKeys.exitedAt.rawValue, value: Date())
        if id == configuration?.id {
            try await stopVirtualMachineAfterMainExit()
        }
        return reply
    }

    @Sendable func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.requiredString(RuntimeKeys.id.rawValue)
        guard let process = processes[id], process.started, let agent = machine?.agent else {
            throw runtimeError(.invalidState, "process \(id) is not running")
        }
        let signalName = try message.requiredString(RuntimeKeys.signal.rawValue)
        let signal = try signalNumber(signalName)
        var request = AgentRequest(operation: .signal)
        request.signal = signal
        _ = try await agent.request(request, processID: process.numericID, timeout: .seconds(10))
        return message.reply()
    }

    @Sendable func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.requiredString(RuntimeKeys.id.rawValue)
        guard let process = processes[id], process.started, let agent = machine?.agent else {
            throw runtimeError(.invalidState, "process \(id) is not running")
        }
        let width = message.uint64(key: RuntimeKeys.width.rawValue)
        let height = message.uint64(key: RuntimeKeys.height.rawValue)
        guard width > 0, width <= UInt16.max, height > 0, height <= UInt16.max else {
            throw runtimeError(.invalidArgument, "invalid terminal size")
        }
        var request = AgentRequest(operation: .resize)
        request.columns = UInt16(width)
        request.rows = UInt16(height)
        _ = try await agent.request(request, processID: process.numericID, timeout: .seconds(10))
        return message.reply()
    }

    @Sendable func deleteProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try message.requiredString(RuntimeKeys.id.rawValue)
        guard let process = processes[id], let agent = machine?.agent else {
            throw runtimeError(.notFound, "process \(id) does not exist")
        }
        _ = try await agent.request(
            AgentRequest(operation: .delete), processID: process.numericID, timeout: .seconds(10)
        )
        await agent.unregister(processID: process.numericID)
        processes.removeValue(forKey: id)
        return message.reply()
    }

    @Sendable func stop(_ message: XPCMessage) async throws -> XPCMessage {
        guard state == .running || state == .booted else {
            if state == .stopped { return message.reply() }
            throw runtimeError(.invalidState, "runtime cannot stop from its current state")
        }
        state = .stopping
        let options = try message.decode(ContainerStopOptions.self, key: RuntimeKeys.stopOptions.rawValue)
        if let mainID = configuration?.id, let process = processes[mainID], process.started,
            let agent = machine?.agent
        {
            var signalRequest = AgentRequest(operation: .signal)
            signalRequest.signal = try signalNumber(options.signal ?? "SIGTERM")
            _ = try? await agent.request(signalRequest, processID: process.numericID, timeout: .seconds(5))
            _ = try? await agent.request(
                AgentRequest(operation: .wait),
                processID: process.numericID,
                timeout: .seconds(max(1, Int(options.timeoutInSeconds)))
            )
        }
        try await stopVirtualMachineAfterMainExit()
        return message.reply()
    }

    @Sendable func stateSnapshot(_ message: XPCMessage) async throws -> XPCMessage {
        let status: RuntimeStatus
        switch state {
        case .running: status = .running
        case .stopping: status = .stopping
        case .created, .booted, .stopped, .shuttingDown: status = .stopped
        }
        let containers: [ContainerSnapshot]
        if let configuration, status == .running {
            containers = [ContainerSnapshot(configuration: configuration, status: status, networks: [])]
        } else { containers = [] }
        let snapshot = SandboxSnapshot(status: status, networks: [], containers: containers)
        let reply = message.reply()
        reply.set(key: RuntimeKeys.snapshot.rawValue, value: try JSONEncoder().encode(snapshot))
        return reply
    }

    @Sendable func copyIn(_ message: XPCMessage) async throws -> XPCMessage {
        guard let agent = machine?.agent else { throw runtimeError(.invalidState, "VM is not booted") }
        let source = try message.requiredString(RuntimeKeys.sourcePath.rawValue)
        let destination = try message.requiredString(RuntimeKeys.destinationPath.rawValue)
        let mode = UInt32(message.uint64(key: RuntimeKeys.fileMode.rawValue))
        let createParents = message.bool(key: RuntimeKeys.createParents.rawValue)
        try await agent.copyIn(
            from: URL(fileURLWithPath: source),
            to: destination,
            mode: mode == 0 ? 0o644 : mode,
            createParents: createParents
        )
        return message.reply()
    }

    @Sendable func copyOut(_ message: XPCMessage) async throws -> XPCMessage {
        guard let agent = machine?.agent else { throw runtimeError(.invalidState, "VM is not booted") }
        let source = try message.requiredString(RuntimeKeys.sourcePath.rawValue)
        let destination = try message.requiredString(RuntimeKeys.destinationPath.rawValue)
        let createParents = message.bool(key: RuntimeKeys.createParents.rawValue)
        try await agent.copyOut(
            from: source,
            to: URL(fileURLWithPath: destination),
            createParents: createParents
        )
        return message.reply()
    }

    @Sendable func unsupportedRoute(_ message: XPCMessage) async throws -> XPCMessage {
        throw unsupported("statistics, networking, socket dialing, mounts, and Linux controls")
    }

    @Sendable func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        guard state == .created || state == .stopped else {
            throw runtimeError(.invalidState, "stop the runtime before shutdown")
        }
        state = .shuttingDown
        Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            Darwin.exit(0)
        }
        return message.reply()
    }

    private func createAgentProcess(
        id: String,
        configuration: RuntimeProcessConfiguration,
        io: ProcessIO
    ) async throws {
        guard let agent = machine?.agent else { throw runtimeError(.invalidState, "VM is not booted") }
        let numericID = nextProcessID
        nextProcessID += 1
        await agent.register(processID: numericID, io: io)
        let response = try await agent.request(
            AgentRequest(operation: .create, process: configuration.agentConfiguration),
            processID: numericID,
            timeout: .seconds(30)
        )
        guard response.ok else { throw runtimeError(.invalidArgument, response.message ?? "agent rejected process") }
        processes[id] = ProcessRecord(
            numericID: numericID,
            configuration: try nativeProcessConfiguration(configuration),
            io: io,
            started: false
        )
    }

    private func processIO(from message: XPCMessage, terminal: Bool) -> ProcessIO {
        var stdout: [FileHandle] = []
        var stderr: [FileHandle] = []
        if let handle = message.fileHandle(key: RuntimeKeys.stdout.rawValue) { stdout.append(handle) }
        if let logHandle { stdout.append(logHandle) }
        if !terminal {
            if let handle = message.fileHandle(key: RuntimeKeys.stderr.rawValue) { stderr.append(handle) }
            if let logHandle { stderr.append(logHandle) }
        }
        return ProcessIO(
            stdin: message.fileHandle(key: RuntimeKeys.stdin.rawValue),
            stdout: stdout,
            stderr: stderr
        )
    }

    private func convert(_ config: ProcessConfiguration) throws -> RuntimeProcessConfiguration {
        let user: RuntimeProcessConfiguration.User
        switch config.user {
        case .id(let uid, let gid): user = .init(uid: uid, gid: gid)
        case .raw(let value): user = .init(raw: value)
        }
        return RuntimeProcessConfiguration(
            executable: config.executable,
            arguments: config.arguments,
            environment: config.environment,
            workingDirectory: config.workingDirectory,
            terminal: config.terminal,
            user: user,
            supplementalGroups: config.supplementalGroups,
            rlimits: config.rlimits.map {
                AgentRLimit(
                    resource: $0.limit.lowercased().replacingOccurrences(of: "rlimit_", with: ""),
                    soft: $0.soft,
                    hard: $0.hard
                )
            }
        )
    }

    private func nativeProcessConfiguration(
        _ config: RuntimeProcessConfiguration
    ) throws -> ProcessConfiguration {
        ProcessConfiguration(
            executable: config.executable,
            arguments: config.arguments,
            environment: config.environment,
            workingDirectory: config.workingDirectory,
            terminal: config.terminal,
            user: config.user.raw.map { .raw(userString: $0) }
                ?? .id(uid: config.user.uid, gid: config.user.gid),
            supplementalGroups: config.supplementalGroups,
            rlimits: config.rlimits.map {
                .init(limit: "RLIMIT_\($0.resource.uppercased())", soft: $0.soft, hard: $0.hard)
            }
        )
    }

    private func decodeDynamicEnvironment(_ message: XPCMessage) throws -> [String: String] {
        guard let data = message.dataNoCopy(key: RuntimeKeys.dynamicEnv.rawValue) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func mergeDynamicEnvironment(
        _ dynamic: [String: String], into process: RuntimeProcessConfiguration
    ) -> RuntimeProcessConfiguration {
        var values: [String: String] = [:]
        for entry in process.environment {
            let pieces = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2 { values[String(pieces[0])] = String(pieces[1]) }
        }
        values.merge(dynamic) { _, new in new }
        return RuntimeProcessConfiguration(
            executable: process.executable,
            arguments: process.arguments,
            environment: values.keys.sorted().map { "\($0)=\(values[$0]!)" },
            workingDirectory: process.workingDirectory,
            terminal: process.terminal,
            user: process.user,
            supplementalGroups: process.supplementalGroups,
            rlimits: process.rlimits
        )
    }

    private func validateV1(_ config: ContainerConfiguration) throws {
        if !config.networks.isEmpty || !config.publishedPorts.isEmpty || !config.publishedSockets.isEmpty {
            throw unsupported("networking, published ports, and published sockets")
        }
        if !config.mounts.isEmpty { throw unsupported("mounts") }
        if config.rosetta { throw unsupported("Rosetta") }
        if !config.capAdd.isEmpty || !config.capDrop.isEmpty || !config.sysctls.isEmpty {
            throw unsupported("Linux capabilities, cgroups, and sysctls")
        }
        if config.virtualization || config.ssh || config.useInit {
            throw unsupported("nested virtualization, SSH forwarding, and Linux init wrapping")
        }
    }

    private func stopVirtualMachineAfterMainExit() async throws {
        guard let machine else { state = .stopped; return }
        _ = try? await machine.agent.request(
            AgentRequest(operation: .shutdown), timeout: .seconds(5)
        )
        try? await Task.sleep(for: .seconds(1))
        if machine.isRunning { try await machine.forceStop() }
        self.machine = nil
        try? logHandle?.close()
        logHandle = nil
        state = .stopped
    }

    private func signalNumber(_ name: String) throws -> Int32 {
        let normalized = name.uppercased().hasPrefix("SIG") ? String(name.uppercased().dropFirst(3)) : name.uppercased()
        let values: [String: Int32] = [
            "HUP": 1, "INT": 2, "QUIT": 3, "KILL": 9, "TERM": 15,
            "STOP": 17, "CONT": 19, "USR1": 30, "USR2": 31, "WINCH": 28,
        ]
        if let value = Int32(normalized), value > 0 { return value }
        guard let value = values[normalized] else {
            throw runtimeError(.invalidArgument, "unsupported signal \(name)")
        }
        return value
    }

    private func unsupported(_ feature: String) -> ContainerizationError {
        runtimeError(.unsupported, "container-runtime-netbsd v1 does not support \(feature)")
    }

    private func runtimeError(
        _ code: ContainerizationError.Code,
        _ message: String
    ) -> ContainerizationError {
        ContainerizationError(code, message: message)
    }
}

private extension XPCMessage {
    func requiredString(_ key: String) throws -> String {
        guard let value = string(key: key), !value.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "missing \(key)")
        }
        return value
    }

    func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard let data = dataNoCopy(key: key) else {
            throw ContainerizationError(.invalidArgument, message: "missing \(key)")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
