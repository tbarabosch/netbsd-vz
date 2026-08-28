import ArgumentParser
import ContainerLog
import ContainerRuntimeClient
import ContainerXPC
import Darwin
import Foundation
import Logging
import NetBSDAgentProtocol
import NetBSDRuntimeCore
import XPC

@main
struct ContainerRuntimeNetBSD: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-runtime-netbsd",
        abstract: "NetBSD Virtualization.framework runtime",
        subcommands: [Start.self, Probe.self]
    )

    struct Probe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "probe",
            abstract: "Boot an agent disk and verify the serial handshake"
        )

        @Option(name: .long) var disk: String
        @Option(name: .long) var state: String
        @Option(name: .long) var timeout: Int = 120

        func run() async throws {
            guard timeout > 0 else { throw ValidationError("--timeout must be positive") }
            let runtimeData = try NetBSDRuntimeData(diskPath: disk)
            let stateURL = URL(fileURLWithPath: state)
            let restarting = FileManager.default.fileExists(
                atPath: stateURL.appendingPathComponent("netbsd-runtime/root.raw").path
            )
            let machine = try NetBSDVirtualMachine(
                root: stateURL,
                runtimeData: runtimeData,
                cpuCount: 2,
                memorySize: 512 * 1024 * 1024
            )
            let hello = try await machine.boot(timeout: .seconds(timeout))
            let ping = try await machine.agent.request(
                AgentRequest(operation: .ping), timeout: .seconds(5)
            )
            print("agent=\(hello.build ?? ping.build ?? "unknown") capabilities=\(hello.capabilities.joined(separator: ","))")
            try await smokeTest(agent: machine.agent, state: stateURL, restarting: restarting)
            _ = try? await machine.agent.request(
                AgentRequest(operation: .shutdown), timeout: .seconds(5)
            )
            try? await Task.sleep(for: .seconds(1))
            if machine.isRunning { try await machine.forceStop() }
        }

        private func smokeTest(agent: AgentConnection, state: URL, restarting: Bool) async throws {
            for name in [
                "copy-source.bin", "copy-destination.bin", "copy-tree", "copy-tree-result",
                "stdio-source.bin", "stdio-destination.bin", "unsafe-copy",
            ] {
                try? FileManager.default.removeItem(at: state.appendingPathComponent(name))
            }
            fputs("probe: literal exec\n", stderr)
            let literal = AgentProcessConfiguration(
                executable: "/usr/bin/printf",
                arguments: ["%s|%s", "one two", "$(id)"],
                environment: ["PATH=/bin:/usr/bin"],
                workingDirectory: "/tmp"
            )
            let literalResult = try await runCaptured(
                agent: agent, processID: 1, configuration: literal
            )
            guard literalResult.exitCode == 0,
                literalResult.stdout == Data("one two|$(id)".utf8),
                literalResult.stderr.isEmpty
            else {
                throw ValidationError("agent did not preserve literal argv/stdout semantics")
            }

            fputs("probe: configured exec\n", stderr)
            let configured = AgentProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s|%s|%s|%s' \"$MARKER\" \"$PWD\" \"$(id -u)\" \"$(ulimit -n)\""],
                environment: ["PATH=/bin:/usr/bin", "MARKER=env-ok"],
                workingDirectory: "/tmp",
                uid: 1,
                gid: 1,
                supplementalGroups: [1],
                rlimits: [AgentRLimit(resource: "nofile", soft: 64, hard: 64)]
            )
            let configuredResult = try await runCaptured(
                agent: agent, processID: 2, configuration: configured
            )
            guard configuredResult.exitCode == 0,
                configuredResult.stdout == Data("env-ok|/tmp|1|64".utf8),
                configuredResult.stderr.isEmpty
            else {
                throw ValidationError("agent did not apply environment/cwd/credentials/rlimits")
            }

            fputs("probe: nonzero exit\n", stderr)
            let nonzeroResult = try await runCaptured(
                agent: agent,
                processID: 3,
                configuration: AgentProcessConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "exit 23"],
                    environment: ["PATH=/bin:/usr/bin"]
                )
            )
            guard nonzeroResult.exitCode == 23 else {
                throw ValidationError("agent did not preserve a nonzero exit status")
            }

            fputs("probe: persistent cloned disk\n", stderr)
            let persistenceResult = try await runCaptured(
                agent: agent,
                processID: 7,
                configuration: AgentProcessConfiguration(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "if [ -f /var/db/nvza-persistence-marker ]; then printf existing; else : > /var/db/nvza-persistence-marker; printf created; fi",
                    ],
                    environment: ["PATH=/bin:/usr/bin"]
                )
            )
            let expectedPersistence = Data((restarting ? "existing" : "created").utf8)
            guard persistenceResult.exitCode == 0,
                persistenceResult.stdout == expectedPersistence
            else {
                throw ValidationError("cloned guest disk did not preserve restart state")
            }

            fputs("probe: concurrent exec\n", stderr)
            try await concurrentProcessSmokeTest(agent: agent)
            fputs("probe: PTY and signal\n", stderr)
            try await terminalSmokeTest(agent: agent)
            fputs("probe: large binary stdio and stdin EOF\n", stderr)
            try await largeStdioSmokeTest(agent: agent, state: state)

            fputs("probe: regular-file copy\n", stderr)
            let copySource = state.appendingPathComponent("copy-source.bin")
            let copyDestination = state.appendingPathComponent("copy-destination.bin")
            let copyBytes = Data((0..<131_072).map { UInt8(truncatingIfNeeded: $0) })
            try copyBytes.write(to: copySource, options: .atomic)
            try await agent.copyInFile(from: copySource, to: "/tmp/nvza-probe.bin", mode: 0o600)
            try await agent.copyOutFile(from: "/tmp/nvza-probe.bin", to: copyDestination)
            guard try Data(contentsOf: copyDestination) == copyBytes else {
                throw ValidationError("agent binary copy round-trip did not match")
            }

            fputs("probe: recursive copy\n", stderr)
            let treeSource = state.appendingPathComponent("copy-tree", isDirectory: true)
            let treeDestination = state.appendingPathComponent("copy-tree-result", isDirectory: true)
            try FileManager.default.createDirectory(
                at: treeSource.appendingPathComponent("empty", isDirectory: true),
                withIntermediateDirectories: true
            )
            try copyBytes.prefix(4097).write(to: treeSource.appendingPathComponent("payload.bin"))
            try FileManager.default.createSymbolicLink(
                atPath: treeSource.appendingPathComponent("payload.link").path,
                withDestinationPath: "payload.bin"
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o751)],
                ofItemAtPath: treeSource.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o640)],
                ofItemAtPath: treeSource.appendingPathComponent("payload.bin").path
            )
            try await agent.copyIn(
                from: treeSource,
                to: "/tmp/nvza-probe-tree",
                mode: 0o755,
                createParents: true
            )
            try await agent.copyOut(
                from: "/tmp/nvza-probe-tree",
                to: treeDestination,
                createParents: true
            )
            guard FileManager.default.fileExists(
                atPath: treeDestination.appendingPathComponent("empty").path
            ), try Data(contentsOf: treeDestination.appendingPathComponent("payload.bin")) == copyBytes.prefix(4097),
                ((try FileManager.default.attributesOfItem(atPath: treeDestination.path)[.posixPermissions]) as? NSNumber)?.uint16Value == 0o751,
                ((try FileManager.default.attributesOfItem(
                    atPath: treeDestination.appendingPathComponent("payload.bin").path
                )[.posixPermissions]) as? NSNumber)?.uint16Value == 0o640,
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: treeDestination.appendingPathComponent("payload.link").path
                ) == "payload.bin"
            else {
                throw ValidationError("agent recursive copy round-trip did not match")
            }

            do {
                try await agent.copyOut(
                    from: "../../etc/passwd",
                    to: state.appendingPathComponent("unsafe-copy")
                )
                throw ValidationError("unsafe copy traversal was accepted")
            } catch NetBSDRuntimeError.invalidConfiguration {
                // Expected: the host rejects traversal before sending a frame.
            }
            print("exec=ok configured-exec=ok nonzero-exit=ok persistence=\(restarting ? "reused" : "created") concurrent=ok pty-signal=ok stdio=ok copy=ok tree-copy=ok traversal=ok")
        }

        private func runCaptured(
            agent: AgentConnection,
            processID: UInt64,
            configuration: AgentProcessConfiguration
        ) async throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
            let stdout = Pipe()
            let stderr = Pipe()
            await agent.register(
                processID: processID,
                io: ProcessIO(
                    stdin: nil,
                    stdout: [stdout.fileHandleForWriting],
                    stderr: [stderr.fileHandleForWriting]
                )
            )
            _ = try await agent.request(
                AgentRequest(operation: .create, process: configuration),
                processID: processID,
                timeout: .seconds(10)
            )
            _ = try await agent.request(
                AgentRequest(operation: .start), processID: processID, timeout: .seconds(10)
            )
            await agent.startStdinPump(processID: processID)
            let wait = try await agent.request(
                AgentRequest(operation: .wait), processID: processID, timeout: .seconds(15)
            )
            _ = try await agent.request(
                AgentRequest(operation: .delete), processID: processID, timeout: .seconds(10)
            )
            await agent.unregister(processID: processID)
            try stdout.fileHandleForWriting.close()
            try stderr.fileHandleForWriting.close()
            return (
                wait.exitCode ?? 255,
                stdout.fileHandleForReading.readDataToEndOfFile(),
                stderr.fileHandleForReading.readDataToEndOfFile()
            )
        }

        private func concurrentProcessSmokeTest(agent: AgentConnection) async throws {
            let process = AgentProcessConfiguration(
                executable: "/bin/sleep",
                arguments: ["1"],
                environment: ["PATH=/bin:/usr/bin"]
            )
            for processID: UInt64 in [3, 4] {
                await agent.register(
                    processID: processID,
                    io: ProcessIO(stdin: nil, stdout: [], stderr: [])
                )
                _ = try await agent.request(
                    AgentRequest(operation: .create, process: process),
                    processID: processID,
                    timeout: .seconds(10)
                )
                _ = try await agent.request(
                    AgentRequest(operation: .start), processID: processID, timeout: .seconds(10)
                )
                await agent.startStdinPump(processID: processID)
            }
            for processID: UInt64 in [3, 4] {
                let wait = try await agent.request(
                    AgentRequest(operation: .wait), processID: processID, timeout: .seconds(10)
                )
                guard wait.exitCode == 0 else {
                    throw ValidationError("concurrent process \(processID) failed")
                }
                _ = try await agent.request(
                    AgentRequest(operation: .delete), processID: processID, timeout: .seconds(10)
                )
                await agent.unregister(processID: processID)
            }
        }

        private func terminalSmokeTest(agent: AgentConnection) async throws {
            let output = Pipe()
            let processID: UInt64 = 5
            await agent.register(
                processID: processID,
                io: ProcessIO(stdin: nil, stdout: [output.fileHandleForWriting], stderr: [])
            )
            let process = AgentProcessConfiguration(
                executable: "/bin/cat",
                environment: ["PATH=/bin:/usr/bin"],
                terminal: true,
                columns: 80,
                rows: 24
            )
            _ = try await agent.request(
                AgentRequest(operation: .create, process: process),
                processID: processID,
                timeout: .seconds(10)
            )
            _ = try await agent.request(
                AgentRequest(operation: .start), processID: processID, timeout: .seconds(10)
            )
            var resize = AgentRequest(operation: .resize)
            resize.columns = 100
            resize.rows = 40
            _ = try await agent.request(resize, processID: processID, timeout: .seconds(10))
            try await agent.sendStdin(Data("pty-probe\n".utf8), processID: processID)
            try await Task.sleep(for: .milliseconds(100))
            var signal = AgentRequest(operation: .signal)
            signal.signal = 15
            _ = try await agent.request(signal, processID: processID, timeout: .seconds(10))
            let wait = try await agent.request(
                AgentRequest(operation: .wait), processID: processID, timeout: .seconds(10)
            )
            guard wait.exitCode == 143 else {
                throw ValidationError("PTY process did not report SIGTERM")
            }
            _ = try await agent.request(
                AgentRequest(operation: .delete), processID: processID, timeout: .seconds(10)
            )
            await agent.unregister(processID: processID)
            try output.fileHandleForWriting.close()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard text.contains("pty-probe") else {
                throw ValidationError("PTY process did not return interactive output")
            }
        }

        private func largeStdioSmokeTest(agent: AgentConnection, state: URL) async throws {
            let source = state.appendingPathComponent("stdio-source.bin")
            let destination = state.appendingPathComponent("stdio-destination.bin")
            let bytes = Data((0..<196_609).map { UInt8(truncatingIfNeeded: $0 * 31) })
            try bytes.write(to: source, options: .atomic)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }

            let processID: UInt64 = 6
            await agent.register(
                processID: processID,
                io: ProcessIO(stdin: input, stdout: [output], stderr: [])
            )
            let process = AgentProcessConfiguration(
                executable: "/bin/cat",
                environment: ["PATH=/bin:/usr/bin"]
            )
            _ = try await agent.request(
                AgentRequest(operation: .create, process: process),
                processID: processID,
                timeout: .seconds(10)
            )
            _ = try await agent.request(
                AgentRequest(operation: .start), processID: processID, timeout: .seconds(10)
            )
            await agent.startStdinPump(processID: processID)
            let wait = try await agent.request(
                AgentRequest(operation: .wait), processID: processID, timeout: .seconds(30)
            )
            guard wait.exitCode == 0 else {
                throw ValidationError("large binary stdio process failed")
            }
            _ = try await agent.request(
                AgentRequest(operation: .delete), processID: processID, timeout: .seconds(10)
            )
            await agent.unregister(processID: processID)
            try output.close()
            guard try Data(contentsOf: destination) == bytes else {
                throw ValidationError("large binary stdin/stdout round-trip did not match")
            }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "start")

        @Flag(name: .long) var debug = false
        @Option(name: .long) var uuid: String
        @Option(name: .long) var root: String

        func run() async throws {
            signal(SIGPIPE, SIG_IGN)
            let log = ServiceLogger.bootstrap(
                category: "ContainerRuntimeNetBSD",
                metadata: ["uuid": "\(uuid)"],
                debug: debug,
                logPath: nil
            )
            nonisolated(unsafe) let anonymousConnection = xpc_connection_create(nil, nil)
            let service = RuntimeService(
                root: URL(fileURLWithPath: root),
                endpointConnection: anonymousConnection,
                log: log
            )
            let label = "com.apple.container.runtime.container-runtime-netbsd.\(uuid)"
            let endpointServer = XPCServer(
                identifier: label,
                routes: [
                    RuntimeRoutes.createEndpoint.rawValue: XPCServer.route(service.createEndpoint)
                ],
                log: log
            )
            let deleteRoute = "com.apple.container.runtime/deleteProcess"
            let server = XPCServer(
                connection: anonymousConnection,
                routes: [
                    RuntimeRoutes.bootstrap.rawValue: XPCServer.route(service.bootstrap),
                    RuntimeRoutes.createProcess.rawValue: XPCServer.route(service.createProcess),
                    RuntimeRoutes.start.rawValue: XPCServer.route(service.startProcess),
                    RuntimeRoutes.wait.rawValue: XPCServer.route(service.wait),
                    RuntimeRoutes.kill.rawValue: XPCServer.route(service.kill),
                    RuntimeRoutes.resize.rawValue: XPCServer.route(service.resize),
                    deleteRoute: XPCServer.route(service.deleteProcess),
                    RuntimeRoutes.stop.rawValue: XPCServer.route(service.stop),
                    RuntimeRoutes.state.rawValue: XPCServer.route(service.stateSnapshot),
                    RuntimeRoutes.copyIn.rawValue: XPCServer.route(service.copyIn),
                    RuntimeRoutes.copyOut.rawValue: XPCServer.route(service.copyOut),
                    RuntimeRoutes.statistics.rawValue: XPCServer.route(service.unsupportedRoute),
                    RuntimeRoutes.dial.rawValue: XPCServer.route(service.unsupportedRoute),
                    RuntimeRoutes.shutdown.rawValue: XPCServer.route(service.shutdown),
                ],
                log: log
            )
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await endpointServer.listen() }
                group.addTask { try await server.listen() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }
}
