import Darwin
import Foundation
import NetBSDAgentProtocol

public struct ProcessIO: @unchecked Sendable {
    public let stdin: FileHandle?
    public let stdout: [FileHandle]
    public let stderr: [FileHandle]

    public init(stdin: FileHandle?, stdout: [FileHandle], stderr: [FileHandle]) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }
}

public actor AgentConnection {
    // NetBSD's tty input queue is approximately 1 KiB. Keep the complete frame
    // below that queue and pace frames with guest acknowledgements. The wire
    // protocol still permits 64 KiB data frames for future vsock transports.
    private static let serialTransferChunkSize = 768
    private static let serialWriteChunkSize = 512
    private let input: FileHandle
    private let output: FileHandle
    private var decoder = FrameDecoder()
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<AgentResponse, Error>] = [:]
    private var requestTimeouts: [UInt64: Task<Void, Never>] = [:]
    private var ready: CheckedContinuation<AgentHello, Error>?
    private var readyTimeout: Task<Void, Never>?
    private var readyRetry: Task<Void, Never>?
    private var processIO: [UInt64: ProcessIO] = [:]
    private var copyCompletion: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var copyAcknowledgements: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var acknowledgedCopies: Set<UInt64> = []
    private var stdinAcknowledgements: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var copyOutputs: [UInt64: FileHandle] = [:]
    private var completedCopies: Set<UInt64> = []
    private var reader: Task<Void, Never>?
    private var terminalError: Error?

    public init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    deinit {
        reader?.cancel()
    }

    public func handshake(timeout: Duration = .seconds(120)) async throws -> AgentHello {
        startReaderIfNeeded()
        return try await beginHandshake(timeout: timeout)
    }

    private func beginHandshake(timeout: Duration) async throws -> AgentHello {
        if let terminalError { throw terminalError }
        let requestID = allocateRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            readyTimeout = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireHandshake()
            }
            do {
                let payload = try ControlCodec.encode(
                    AgentHello(version: AgentProtocol.version, capabilities: ["serial-v1"])
                )
                try write(Frame(type: .hostHello, requestID: requestID, payload: payload))
                readyRetry = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        await self?.retryHandshake(requestID: requestID, payload: payload)
                    }
                }
            } catch {
                ready = nil
                continuation.resume(throwing: error)
            }
        }
    }

    public func request(
        _ request: AgentRequest,
        processID: UInt64 = 0,
        timeout: Duration? = nil
    ) async throws -> AgentResponse {
        try await performRequest(request, processID: processID, timeout: timeout)
    }

    private func performRequest(
        _ request: AgentRequest,
        processID: UInt64,
        timeout: Duration? = nil
    ) async throws -> AgentResponse {
        if let terminalError { throw terminalError }
        let requestID = allocateRequestID()
        let payload = try ControlCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            if let timeout {
                requestTimeouts[requestID] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expireRequest(requestID, operation: request.operation.rawValue)
                }
            }
            do {
                try write(Frame(
                    type: .request,
                    requestID: requestID,
                    processID: processID,
                    payload: payload
                ))
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    public func register(processID: UInt64, io: ProcessIO) {
        processIO[processID] = io
    }

    public func unregister(processID: UInt64) {
        processIO.removeValue(forKey: processID)
    }

    public func startStdinPump(processID: UInt64) {
        guard let handle = processIO[processID]?.stdin else {
            Task { [weak self] in
                _ = try? await self?.request(
                    AgentRequest(operation: .closeStdin),
                    processID: processID,
                    timeout: .seconds(10)
                )
            }
            return
        }
        Task.detached { [weak self] in
            do {
                while let data = try handle.read(upToCount: Self.serialTransferChunkSize),
                    !data.isEmpty
                {
                    try await self?.sendStdin(data, processID: processID)
                }
                let close = AgentRequest(operation: .closeStdin)
                _ = try await self?.request(close, processID: processID)
            } catch {
                await self?.failProcessInput(processID: processID, error: error)
            }
        }
    }

    public func sendStdin(_ data: Data, processID: UInt64) async throws {
        guard data.count <= Self.serialTransferChunkSize else {
            throw FrameCodecError.payloadTooLarge(data.count)
        }
        let requestID = allocateRequestID()
        try await withCheckedThrowingContinuation { continuation in
            stdinAcknowledgements[requestID] = continuation
            do {
                try write(Frame(
                    type: .stdin,
                    requestID: requestID,
                    processID: processID,
                    payload: data
                ))
            } catch {
                stdinAcknowledgements.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    public func copyInFile(
        from source: URL,
        to destination: String,
        mode: UInt32
    ) async throws {
        try await copyIn(from: source, to: destination, rootMode: mode)
    }

    public func copyIn(from source: URL, to destination: String, mode: UInt32) async throws {
        try await copyIn(from: source, to: destination, mode: mode, createParents: true)
    }

    public func copyIn(
        from source: URL,
        to destination: String,
        mode: UInt32,
        createParents: Bool
    ) async throws {
        try await copyIn(
            from: source,
            to: destination,
            rootMode: mode,
            createParents: createParents
        )
    }

    private func copyIn(
        from source: URL,
        to destination: String,
        rootMode: UInt32?,
        createParents: Bool = false
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let fileType = attributes[.type] as? FileAttributeType else {
            throw NetBSDRuntimeError.invalidConfiguration("cannot determine copy-in source type")
        }
        let sourceMode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        let effectiveMode = fileType == .typeRegular
            ? (rootMode.flatMap { $0 == 0 ? nil : $0 } ?? sourceMode)
            : sourceMode
        let guestPath = try Self.relativeGuestPath(destination)

        if fileType == .typeDirectory {
            var request = AgentRequest(operation: .copyIn)
            request.path = guestPath
            request.entryType = "directory"
            request.mode = effectiveMode
            request.size = 0
            request.createParents = createParents
            _ = try await performRequest(request, processID: 0, timeout: .seconds(30))
            let children = try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try Self.validateCopyComponent(child.lastPathComponent)
                try await copyIn(
                    from: child,
                    to: guestPath + "/" + child.lastPathComponent,
                    rootMode: nil,
                    createParents: false
                )
            }
            return
        }

        if fileType == .typeSymbolicLink {
            var request = AgentRequest(operation: .copyIn)
            request.path = guestPath
            request.entryType = "symlink"
            request.mode = effectiveMode
            request.size = 0
            request.linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            request.createParents = createParents
            _ = try await performRequest(request, processID: 0, timeout: .seconds(30))
            return
        }

        guard fileType == .typeRegular,
            let byteCount = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            throw NetBSDRuntimeError.unsupported("v1 copy does not support this file type")
        }
        var request = AgentRequest(operation: .copyIn)
        request.path = guestPath
        request.entryType = "regular"
        request.mode = effectiveMode
        request.size = byteCount
        request.createParents = createParents

        let requestID = allocateRequestID()
        let response = try await performRequestWithID(request, processID: 0, requestID: requestID)
        guard response.ok else {
            throw NetBSDRuntimeError.protocolFailure(response.message ?? "copy-in rejected")
        }
        if byteCount != 0 {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: Self.serialTransferChunkSize), !data.isEmpty {
                try write(Frame(type: .copyData, requestID: requestID, payload: data))
                try await waitForCopyAcknowledgement(requestID)
            }
            try await waitForCopy(requestID)
        }
    }

    public func copyOutFile(from source: String, to destination: URL) async throws {
        var request = AgentRequest(operation: .copyOut)
        request.path = try Self.relativeGuestPath(source)
        let requestID = allocateRequestID()
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        copyOutputs[requestID] = handle
        do {
            let response = try await performRequestWithID(request, processID: 0, requestID: requestID)
            guard response.ok, response.entryType == "regular" else {
                throw NetBSDRuntimeError.protocolFailure(response.message ?? "copy-out rejected")
            }
            try await waitForCopy(requestID)
            if let mode = response.mode {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: destination.path
                )
            }
        } catch {
            copyOutputs.removeValue(forKey: requestID)
            copyCompletion.removeValue(forKey: requestID)?.resume(throwing: error)
            try? handle.close()
            throw error
        }
    }

    public func copyOut(
        from source: String,
        to destination: URL,
        createParents: Bool = true
    ) async throws {
        if createParents {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let guestPath = try Self.relativeGuestPath(source)
        try await copyOutEntry(from: guestPath, to: destination)
    }

    private func copyOutEntry(from source: String, to destination: URL) async throws {
        var request = AgentRequest(operation: .copyList)
        request.path = try Self.relativeGuestPath(source)
        let response = try await performRequest(request, processID: 0, timeout: .seconds(30))
        guard response.ok, let entries = response.entries, let root = entries.first,
            root.path.isEmpty
        else {
            throw NetBSDRuntimeError.protocolFailure("copy-list returned invalid metadata")
        }

        switch root.type {
        case "regular":
            try await copyOutFile(from: source, to: destination)
        case "symlink":
            guard let target = root.linkTarget else {
                throw NetBSDRuntimeError.protocolFailure("symlink metadata is missing its target")
            }
            try Self.removeExistingCopyDestination(destination)
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        case "directory":
            try Self.prepareCopyDirectory(destination)
            for child in entries.dropFirst() {
                try Self.validateCopyComponent(child.path)
                try await copyOutEntry(
                    from: source + "/" + child.path,
                    to: destination.appendingPathComponent(child.path)
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: root.mode)],
                ofItemAtPath: destination.path
            )
        default:
            throw NetBSDRuntimeError.unsupported("guest copy entry type \(root.type)")
        }
    }

    private func performRequestWithID(
        _ request: AgentRequest,
        processID: UInt64,
        requestID: UInt64
    ) async throws -> AgentResponse {
        let payload = try ControlCodec.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            do {
                try write(Frame(type: .request, requestID: requestID, processID: processID, payload: payload))
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func waitForCopy(_ requestID: UInt64) async throws {
        if completedCopies.remove(requestID) != nil { return }
        try await withCheckedThrowingContinuation { continuation in
            copyCompletion[requestID] = continuation
        }
    }

    private func waitForCopyAcknowledgement(_ requestID: UInt64) async throws {
        if acknowledgedCopies.remove(requestID) != nil { return }
        try await withCheckedThrowingContinuation { continuation in
            copyAcknowledgements[requestID] = continuation
        }
    }

    private static func relativeGuestPath(_ path: String) throws -> String {
        let candidate = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard !candidate.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw NetBSDRuntimeError.invalidConfiguration("unsafe guest copy path: \(path)") }
        return candidate
    }

    private static func validateCopyComponent(_ component: String) throws {
        guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
            throw NetBSDRuntimeError.invalidConfiguration("unsafe copy path component: \(component)")
        }
    }

    private static func removeExistingCopyDestination(_ destination: URL) throws {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: destination.path)
            try FileManager.default.removeItem(at: destination)
        } catch CocoaError.fileReadNoSuchFile {
            return
        }
    }

    private static func prepareCopyDirectory(_ destination: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw NetBSDRuntimeError.invalidConfiguration(
                    "copy-out destination exists and is not a directory: \(destination.path)"
                )
            }
        } catch CocoaError.fileReadNoSuchFile {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
    }

    private func startReaderIfNeeded() {
        guard reader == nil else { return }
        let descriptor = input.fileDescriptor
        reader = Task.detached { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            while !Task.isCancelled {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                }
                if count > 0 {
                    do {
                        try await self?.receive(Data(bytes.prefix(count)))
                    } catch {
                        await self?.fail(error)
                        return
                    }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    let error: any Error = count == 0
                        ? NetBSDRuntimeError.protocolFailure("agent serial channel closed")
                        : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    await self?.fail(error)
                    return
                }
            }
        }
    }

    private func receive(_ data: Data) throws {
        try decoder.append(data)
        while true {
            do {
                guard let frame = try decoder.next() else { return }
                try dispatch(frame)
            } catch {
                if ready != nil {
                    decoder = FrameDecoder()
                    return
                }
                throw error
            }
        }
    }

    private func dispatch(_ frame: Frame) throws {
        switch frame.header.type {
        case .guestReady:
            let hello = try ControlCodec.decode(AgentHello.self, from: frame.payload)
            readyTimeout?.cancel()
            readyTimeout = nil
            readyRetry?.cancel()
            readyRetry = nil
            ready?.resume(returning: hello)
            ready = nil
        case .response:
            let response = try ControlCodec.decode(AgentResponse.self, from: frame.payload)
            requestTimeouts.removeValue(forKey: frame.header.requestID)?.cancel()
            pending.removeValue(forKey: frame.header.requestID)?.resume(returning: response)
        case .error:
            let response = try ControlCodec.decode(AgentResponse.self, from: frame.payload)
            let error = NetBSDRuntimeError.protocolFailure(
                "\(response.code ?? "agent-error"): \(response.message ?? "request failed")"
            )
            requestTimeouts.removeValue(forKey: frame.header.requestID)?.cancel()
            if let continuation = stdinAcknowledgements.removeValue(forKey: frame.header.requestID) {
                continuation.resume(throwing: error)
            } else {
                pending.removeValue(forKey: frame.header.requestID)?.resume(throwing: error)
            }
        case .stdout:
            try write(frame.payload, to: processIO[frame.header.processID]?.stdout ?? [])
        case .stderr:
            try write(frame.payload, to: processIO[frame.header.processID]?.stderr ?? [])
        case .event:
            let event = try ControlCodec.decode(AgentEvent.self, from: frame.payload)
            if (event.event == "copyProgress" || event.event == "copyComplete"),
                let requestID = event.requestID
            {
                if let continuation = copyAcknowledgements.removeValue(forKey: requestID) {
                    continuation.resume()
                } else {
                    acknowledgedCopies.insert(requestID)
                }
            }
            if event.event == "stdinAck" {
                stdinAcknowledgements.removeValue(forKey: frame.header.requestID)?.resume()
            }
            if event.event == "copyComplete", let requestID = event.requestID {
                if let continuation = copyCompletion.removeValue(forKey: requestID) {
                    continuation.resume()
                } else {
                    completedCopies.insert(requestID)
                }
            }
        case .copyData:
            guard let handle = copyOutputs[frame.header.requestID] else {
                throw NetBSDRuntimeError.protocolFailure("copy data has no destination")
            }
            try handle.write(contentsOf: frame.payload)
        case .streamEOF:
            if frame.header.requestID != 0, frame.payload == Data("copy".utf8) {
                if let handle = copyOutputs.removeValue(forKey: frame.header.requestID) {
                    try? handle.close()
                }
                if let continuation = copyCompletion.removeValue(forKey: frame.header.requestID) {
                    continuation.resume()
                } else {
                    completedCopies.insert(frame.header.requestID)
                }
            }
        default:
            throw NetBSDRuntimeError.protocolFailure(
                "unexpected agent frame type \(frame.header.type.rawValue)"
            )
        }
    }

    private func write(_ data: Data, to handles: [FileHandle]) throws {
        for handle in handles { try handle.write(contentsOf: data) }
    }

    private func write(_ frame: Frame) throws {
        let encoded = try frame.encoded()
        var offset = 0
        while offset < encoded.count {
            let end = min(offset + Self.serialWriteChunkSize, encoded.count)
            try output.write(contentsOf: encoded[offset..<end])
            offset = end
            if offset < encoded.count {
                // Yield to the guest reader before its small tty queue fills.
                usleep(2_000)
            }
        }
    }

    private func allocateRequestID() -> UInt64 {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private func failProcessInput(processID: UInt64, error: Error) {
        // Output and process wait remain usable if the caller closes stdin unexpectedly.
    }

    private func expireHandshake() {
        guard let continuation = ready else { return }
        ready = nil
        readyRetry?.cancel()
        readyRetry = nil
        continuation.resume(throwing: NetBSDRuntimeError.timeout("timed out waiting for agent handshake"))
    }

    private func retryHandshake(requestID: UInt64, payload: Data) {
        guard ready != nil else { return }
        do {
            try write(Frame(type: .hostHello, requestID: requestID, payload: payload))
        } catch {
            fail(error)
        }
    }

    private func expireRequest(_ requestID: UInt64, operation: String) {
        requestTimeouts.removeValue(forKey: requestID)
        pending.removeValue(forKey: requestID)?.resume(
            throwing: NetBSDRuntimeError.timeout("timed out waiting for agent \(operation)")
        )
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        readyTimeout?.cancel()
        readyTimeout = nil
        readyRetry?.cancel()
        readyRetry = nil
        ready?.resume(throwing: error)
        ready = nil
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        for task in requestTimeouts.values { task.cancel() }
        requestTimeouts.removeAll()
        for continuation in copyCompletion.values { continuation.resume(throwing: error) }
        copyCompletion.removeAll()
        for continuation in copyAcknowledgements.values { continuation.resume(throwing: error) }
        copyAcknowledgements.removeAll()
        acknowledgedCopies.removeAll()
        for continuation in stdinAcknowledgements.values { continuation.resume(throwing: error) }
        stdinAcknowledgements.removeAll()
        for handle in copyOutputs.values { try? handle.close() }
        copyOutputs.removeAll()
    }
}
