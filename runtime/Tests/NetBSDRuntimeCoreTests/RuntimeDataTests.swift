import Foundation
import Testing
@testable import NetBSDRuntimeCore

@Test func runtimeDataRejectsRelativeAndMalformedDigest() throws {
    #expect(throws: NetBSDRuntimeError.self) {
        try NetBSDRuntimeData(diskPath: "disk.raw")
    }
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("netbsd-runtime-data-\(UUID().uuidString).raw")
    FileManager.default.createFile(atPath: temporary.path, contents: Data(repeating: 0, count: 512))
    defer { try? FileManager.default.removeItem(at: temporary) }
    #expect(throws: NetBSDRuntimeError.self) {
        try NetBSDRuntimeData(diskPath: temporary.path, diskSHA512: "abcd")
    }
}

@Test func runtimeDataRoundTrips() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("netbsd-runtime-data-\(UUID().uuidString).raw")
    FileManager.default.createFile(atPath: temporary.path, contents: Data(repeating: 0x5a, count: 512))
    defer { try? FileManager.default.removeItem(at: temporary) }
    let value = try NetBSDRuntimeData(diskPath: temporary.path)
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(NetBSDRuntimeData.self, from: encoded) == value)
    #expect(value.schemaVersion == 1)

    let digest = try NetBSDRuntimeData.sha512(of: temporary)
    let v2 = try NetBSDRuntimeData(
        diskPath: temporary.path,
        diskSHA512: digest,
        imageReference: "ghcr.io/tbarabosch/netbsd:11",
        manifestDigest: "sha256:" + String(repeating: "a", count: 64),
        platformKitDigest: "sha256:" + String(repeating: "b", count: 64),
        assemblerVersion: "netbsd-oci-disk/1"
    )
    let encodedV2 = try JSONEncoder().encode(v2)
    #expect(try JSONDecoder().decode(NetBSDRuntimeData.self, from: encodedV2) == v2)
    #expect(v2.schemaVersion == 2)
    #expect(try v2.validatedDisk() == temporary.standardizedFileURL)
}

@Test func runtimeDataRejectsIncompleteV2() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("netbsd-runtime-data-\(UUID().uuidString).raw")
    FileManager.default.createFile(atPath: temporary.path, contents: Data(repeating: 0, count: 512))
    defer { try? FileManager.default.removeItem(at: temporary) }
    let encoded = Data("""
        {"schemaVersion":2,"diskPath":"\(temporary.path)"}
        """.utf8)
    #expect(throws: NetBSDRuntimeError.self) {
        try JSONDecoder().decode(NetBSDRuntimeData.self, from: encoded)
    }
}
