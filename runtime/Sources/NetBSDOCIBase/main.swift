import ArgumentParser
import Foundation
import NetBSDOCI

@main
struct NetBSDOCIBaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "netbsd-oci-base",
        abstract: "Build a reproducible netbsd/arm64 OCI base-image layout"
    )

    @Option(name: .long, help: "Verified NetBSD base.tar.xz set")
    var base: String

    @Option(name: .long, help: "Verified NetBSD etc.tar.xz set")
    var etc: String

    @Option(name: .long, help: "Output OCI layout directory")
    var output: String

    mutating func run() throws {
        try NetBSDBaseImageBuilder().build(
            baseSet: URL(fileURLWithPath: base),
            etcSet: URL(fileURLWithPath: etc),
            output: URL(fileURLWithPath: output)
        )
    }
}
