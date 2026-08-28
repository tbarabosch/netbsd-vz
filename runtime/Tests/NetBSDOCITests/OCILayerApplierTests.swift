import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation
import Testing

@testable import NetBSDOCI

private struct TestEntry {
    let path: String
    let type: URLFileResourceType
    let data: Data
    let target: String?
    let xattrs: [String: Data]

    init(
        _ path: String,
        type: URLFileResourceType = .regular,
        data: Data = Data(),
        target: String? = nil,
        xattrs: [String: Data] = [:]
    ) {
        self.path = path
        self.type = type
        self.data = data
        self.target = target
        self.xattrs = xattrs
    }
}

private func sha256(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func layer(
    entries: [TestEntry],
    filter: ContainerizationArchive.Filter = .none,
    mediaType: String = MediaTypes.imageLayer
) throws -> (OCILayerSource, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("netbsd-oci-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let uncompressed = directory.appendingPathComponent("diff.tar")
    let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: uncompressed)
    for value in entries {
        let entry = WriteEntry()
        entry.path = value.path
        entry.fileType = value.type
        entry.permissions = value.type == .directory ? 0o755 : 0o644
        entry.owner = 123
        entry.group = 456
        entry.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        entry.xattrs = value.xattrs
        entry.size = value.type == .regular && value.target == nil ? Int64(value.data.count) : 0
        if value.type == .symbolicLink { entry.symlinkTarget = value.target }
        if value.type == .regular, let target = value.target { entry.hardlink = target }
        try writer.writeEntry(entry: entry, data: value.data)
    }
    try writer.finishEncoding()

    let blob: URL
    if filter == .none {
        blob = uncompressed
    } else if filter == .zstd {
        blob = directory.appendingPathComponent("blob")
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NetBSDOCIError.unsupported("zstd encoder is unavailable for this test")
        }
        guard FileManager.default.createFile(atPath: blob.path, contents: nil) else {
            throw NetBSDOCIError.io("cannot create zstd test blob")
        }
        let output = try FileHandle(forWritingTo: blob)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-q", "-c", uncompressed.path]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        try output.close()
        guard process.terminationStatus == 0 else {
            throw NetBSDOCIError.invalidLayer("zstd test compression failed")
        }
    } else {
        blob = directory.appendingPathComponent("blob")
        let compressed = try ArchiveWriter(format: .paxRestricted, filter: filter, file: blob)
        let reader = try ArchiveReader(file: uncompressed)
        for (entry, data) in reader { try compressed.writeEntry(entry: entry, data: data) }
        try compressed.finishEncoding()
    }
    let descriptor = Descriptor(
        mediaType: mediaType,
        digest: "sha256:\(try sha256(blob))",
        size: Int64((try blob.resourceValues(forKeys: [.fileSizeKey])).fileSize!)
    )
    return (
        OCILayerSource(
            descriptor: descriptor,
            diffID: "sha256:\(try sha256(uncompressed))",
            file: blob
        ),
        directory
    )
}

@Test func appliesLayersWhiteoutsAndMetadata() throws {
    let (lower, lowerDirectory) = try layer(entries: [
        TestEntry("etc", type: .directory),
        TestEntry("etc/remove", data: Data("old".utf8)),
        TestEntry("etc/keep", data: Data("keep".utf8)),
    ])
    let (upper, upperDirectory) = try layer(entries: [
        TestEntry("etc/.wh.remove"),
        TestEntry("etc/new", data: Data("new".utf8)),
    ])
    defer {
        try? FileManager.default.removeItem(at: lowerDirectory)
        try? FileManager.default.removeItem(at: upperDirectory)
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("netbsd-oci-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try OCILayerApplier().apply([lower, upper], to: root)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("etc/remove").path))
    #expect(try String(contentsOf: root.appendingPathComponent("etc/keep"), encoding: .utf8) == "keep")
    #expect(try String(contentsOf: root.appendingPathComponent("etc/new"), encoding: .utf8) == "new")
    #expect(result.metadata["etc/new"]?.uid == 123)
    #expect(result.metadata["etc/new"]?.gid == 456)
}

@Test func appliesOpaqueWhiteoutsAndHardlinks() throws {
    let (lower, lowerDirectory) = try layer(entries: [
        TestEntry("tree", type: .directory),
        TestEntry("tree/old", data: Data("old".utf8)),
        TestEntry("outside", data: Data("outside".utf8)),
    ])
    let (upper, upperDirectory) = try layer(entries: [
        TestEntry("tree/.wh..wh..opq"),
        TestEntry("tree/new", data: Data("new".utf8)),
        TestEntry("tree/linked", target: "tree/new"),
    ])
    defer {
        try? FileManager.default.removeItem(at: lowerDirectory)
        try? FileManager.default.removeItem(at: upperDirectory)
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("netbsd-oci-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try OCILayerApplier().apply([lower, upper], to: root)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tree/old").path))
    #expect(try String(contentsOf: root.appendingPathComponent("outside"), encoding: .utf8) == "outside")
    #expect(try String(contentsOf: root.appendingPathComponent("tree/linked"), encoding: .utf8) == "new")
    let original = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("tree/new").path)
    let linked = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("tree/linked").path)
    #expect(original[.systemFileNumber] as? NSNumber == linked[.systemFileNumber] as? NSNumber)
}

@Test func rejectsTraversalAndXattrs() throws {
    for entries in [
        [TestEntry("../escape", data: Data("bad".utf8))],
        [TestEntry("file", data: Data("bad".utf8), xattrs: ["user.bad": Data([1])])],
    ] {
        let (source, directory) = try layer(entries: entries)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbsd-oci-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: NetBSDOCIError.self) {
            try OCILayerApplier().apply([source], to: root)
        }
    }
}

@Test func rejectsSpecialFilesAndDigestMismatches() throws {
    let (special, specialDirectory) = try layer(entries: [TestEntry("fifo", type: .namedPipe)])
    defer { try? FileManager.default.removeItem(at: specialDirectory) }
    let specialRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("netbsd-oci-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: specialRoot) }
    #expect(throws: NetBSDOCIError.self) {
        try OCILayerApplier().apply([special], to: specialRoot)
    }

    let (valid, validDirectory) = try layer(entries: [TestEntry("file", data: Data("safe".utf8))])
    defer { try? FileManager.default.removeItem(at: validDirectory) }
    let invalid = OCILayerSource(
        descriptor: valid.descriptor,
        diffID: "sha256:" + String(repeating: "0", count: 64),
        file: valid.file
    )
    let digestRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("netbsd-oci-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: digestRoot) }
    #expect(throws: NetBSDOCIError.self) {
        try OCILayerApplier().apply([invalid], to: digestRoot)
    }
}

@Test func verifiesGzipAndZstdDiffIDs() throws {
    for (filter, mediaType) in [
        (ContainerizationArchive.Filter.gzip, MediaTypes.imageLayerGzip),
        (ContainerizationArchive.Filter.zstd, MediaTypes.imageLayerZstd),
    ] {
        let (source, directory) = try layer(
            entries: [TestEntry("hello", data: Data("world".utf8))],
            filter: filter,
            mediaType: mediaType
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("netbsd-oci-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try OCILayerApplier().apply([source], to: root)
        #expect(try String(contentsOf: root.appendingPathComponent("hello"), encoding: .utf8) == "world")
    }
}
