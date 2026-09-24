import Foundation
import Testing
@testable import Ghostty

struct CLIAgentDetectorTests {
    @Test func childPIDsListsDirectChildren() throws {
        var children: [Process] = []
        defer { children.forEach { $0.terminate() } }
        for _ in 0..<3 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["30"]
            try p.run()
            children.append(p)
        }

        let found = Set(CLIAgentDetector.childPIDs(of: getpid()))
        #expect(Set(children.map(\.processIdentifier)).isSubset(of: found))
    }

    @Test func childPIDsExcludesGrandchildren() throws {
        // sh stays alive as the parent of sleep, so sleep is a grandchild of
        // the test process.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "/bin/sleep 30; true"]
        try p.run()
        var grandchildren: [Int32] = []
        defer {
            grandchildren.forEach { kill($0, SIGKILL) }
            p.terminate()
        }

        for _ in 0..<100 where grandchildren.isEmpty {
            grandchildren = CLIAgentDetector.childPIDs(of: p.processIdentifier)
            if grandchildren.isEmpty { usleep(10_000) }
        }
        try #require(!grandchildren.isEmpty)
        let direct = CLIAgentDetector.childPIDs(of: getpid())
        #expect(direct.contains(p.processIdentifier))
        #expect(grandchildren.allSatisfy { !direct.contains($0) })
    }

    @Test func childPIDsOfChildlessProcessIsEmpty() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        defer { p.terminate() }
        #expect(CLIAgentDetector.childPIDs(of: p.processIdentifier).isEmpty)
    }
}
