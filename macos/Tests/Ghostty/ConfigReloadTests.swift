import Foundation
import Testing
@testable import Ghostty

@Suite
struct ConfigReloadTests {
    /// A directory holding a config file plus the files it references,
    /// removed when the test ends.
    final class Fixture {
        let directory: URL
        let config: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            config = directory.appendingPathComponent("config.ghostty")
        }

        func write(_ name: String, _ text: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Verdicts

    @Test func emptyFileIsAccepted() throws {
        let config = try TemporaryConfig("")
        guard case .accept(let candidate) = Ghostty.Config.verdict(at: config.temporaryFile.path()) else {
            Issue.record("空配置文件被拒绝")
            return
        }
        #expect(!candidate.loadFailed)
        #expect(candidate.errors.isEmpty)
        #expect(candidate.loadPaths.contains(config.temporaryFile.path()))
    }

    @Test func validFileIsApplied() throws {
        let config = try TemporaryConfig("cursor-style = block")
        guard case .accept = Ghostty.Config.verdict(at: config.temporaryFile.path()) else {
            Issue.record("a valid configuration was rejected")
            return
        }
    }

    /// The same observation the running app is checked with: a candidate
    /// that sets title and also contains an error must be rejected whole,
    /// so the title it sets never reaches the running configuration.
    @Test func invalidCandidateIsRejectedWhole() throws {
        let broken = try TemporaryConfig("title = Replaced\nnot-a-real-field = 1")
        guard case .reject(_, let candidate) = Ghostty.Config.verdict(at: broken.temporaryFile.path()),
              let candidate, !candidate.errors.isEmpty else {
            Issue.record("a candidate that sets title alongside an error was accepted")
            return
        }
        let previous = try TemporaryConfig("title = Kept")
        #expect(previous.title == "Kept")
    }

    @Test func unknownFieldRejectsTheWholeFile() throws {
        let config = try TemporaryConfig("not-a-real-field = 1\ncursor-style = block")
        guard case .reject(_, let candidate) = Ghostty.Config.verdict(at: config.temporaryFile.path()),
              let candidate, !candidate.errors.isEmpty else {
            Issue.record("an unknown field was accepted")
            return
        }
    }

    @Test func invalidValueRejectsTheWholeFile() throws {
        let config = try TemporaryConfig("cursor-style = sideways")
        guard case .reject(_, let candidate) = Ghostty.Config.verdict(at: config.temporaryFile.path()),
              let candidate, !candidate.errors.isEmpty else {
            Issue.record("an invalid value was accepted")
            return
        }
    }

    @Test func missingFileCannotBeLoaded() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
            .path()
        guard case .reject(_, let candidate) = Ghostty.Config.verdict(at: missing),
              let candidate, !candidate.errors.isEmpty else {
            Issue.record("a missing configuration was treated as loaded")
            return
        }
    }

    @Test func missingReferencedFileRejectsTheWholeFile() throws {
        let config = try TemporaryConfig("config-file = /ghostty-does-not-exist/extra")
        guard case .reject(_, let candidate) = Ghostty.Config.verdict(at: config.temporaryFile.path()),
              let candidate, !candidate.errors.isEmpty else {
            Issue.record("a missing config-file was accepted")
            return
        }
    }

    @Test func referencedFileIsReportedAsADependency() throws {
        let fixture = try Fixture()
        let extra = try fixture.write("extra", "cursor-style = underline\n")
        let config = try TemporaryConfig("config-file = \(extra.path())\n")
        #expect(config.loadPaths.contains(extra.path()))
    }

    @Test func themeFileIsReportedAsADependency() throws {
        let fixture = try Fixture()
        let theme = try fixture.write("theme", "background = #111111\n")
        let config = try TemporaryConfig("theme = \(theme.path())\n")
        #expect(config.loadPaths.contains(theme.path()))
    }

    // MARK: - Watching

    @Test func writingValidContentToAnEmptyFileReloads() async throws {
        let config = try TemporaryConfig("")
        let reloader = ConfigReloader()
        defer { reloader.stop() }
        let changes = ChangeCounter()
        let path = config.temporaryFile.path()
        reloader.onChange = {
            guard case .accept(let candidate) = Ghostty.Config.verdict(at: path),
                  candidate.title == "AfterEmpty" else {
                Issue.record("空文件写入合法内容后未加载新配置")
                return
            }
            changes.record()
        }
        reloader.watch(config.loadPaths)
        try await Task.sleep(for: .milliseconds(100))

        try "title = AfterEmpty\n".write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        try await changes.waitFor(1)
    }

    @Test func consecutiveAtomicSavesEachReload() async throws {
        let config = try TemporaryConfig("cursor-style = block")
        let reloader = ConfigReloader()
        defer { reloader.stop() }
        let changes = ChangeCounter()
        reloader.onChange = { changes.record() }
        reloader.watch(config.loadPaths)
        try await Task.sleep(for: .milliseconds(100))

        for index in 1...3 {
            try "cursor-style = underline\n# \(index)\n".write(
                to: config.temporaryFile, atomically: true, encoding: .utf8)
            try await changes.waitFor(index)
        }
    }

    @Test func releasingTheWatcherClosesItsDescriptors() async throws {
        let config = try TemporaryConfig("cursor-style = block")
        let watched = config.temporaryFile.resolvingSymlinksInPath().path()
        do {
            let reloader = ConfigReloader()
            reloader.watch(config.loadPaths)
            try await Task.sleep(for: .milliseconds(200))
            #expect(descriptors(of: watched) > 0)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(descriptors(of: watched) == 0)
    }

    @Test func stoppingTheWatcherDropsLaterSaves() async throws {
        let config = try TemporaryConfig("cursor-style = block")
        let reloader = ConfigReloader()
        let changes = ChangeCounter()
        reloader.onChange = { changes.record() }
        reloader.watch(config.loadPaths)
        try await Task.sleep(for: .milliseconds(100))
        reloader.stop()
        try await Task.sleep(for: .milliseconds(100))

        try "cursor-style = underline\n".write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        let current = await MainActor.run { changes.current }
        #expect(current == 0)
    }

    @Test func savingTheFileReloads() async throws {
        let config = try TemporaryConfig("cursor-style = block")
        let reloader = ConfigReloader()
        let changes = ChangeCounter()
        reloader.onChange = { changes.record() }
        reloader.watch(config.loadPaths)

        try "cursor-style = underline\n".write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        try await changes.waitFor(1)
        reloader.stop()
    }

    @Test func atomicRenameReloads() async throws {
        let config = try TemporaryConfig("cursor-style = block")
        let reloader = ConfigReloader()
        let changes = ChangeCounter()
        reloader.onChange = { changes.record() }
        reloader.watch(config.loadPaths)

        let replacement = config.temporaryFile
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try "cursor-style = underline\n".write(to: replacement, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(config.temporaryFile, withItemAt: replacement)
        try await changes.waitFor(1)
        reloader.stop()
    }

    @Test func recreatingADeletedFileReloads() async throws {
        let config = try TemporaryConfig("cursor-style = block")
        let reloader = ConfigReloader()
        let changes = ChangeCounter()
        reloader.onChange = { changes.record() }
        reloader.watch([config.temporaryFile.path(), config.temporaryFile.deletingLastPathComponent().path()])

        try FileManager.default.removeItem(at: config.temporaryFile)
        try await changes.waitFor(1)
        try "cursor-style = underline\n".write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        try await changes.waitFor(2)
        reloader.stop()
    }

    @Test func changingAReferencedFileReloads() async throws {
        let fixture = try Fixture()
        let extra = try fixture.write("extra", "cursor-style = block\n")
        let config = try TemporaryConfig("config-file = \(extra.path())\n")
        let reloader = ConfigReloader()
        let changes = ChangeCounter()
        reloader.onChange = { changes.record() }
        reloader.watch(config.loadPaths)

        try "cursor-style = underline\n".write(to: extra, atomically: true, encoding: .utf8)
        try await changes.waitFor(1)
        reloader.stop()
    }

    @Test func aRejectedLoadKeepsWatching() async throws {
        let config = try TemporaryConfig("cursor-style = block")
        let reloader = ConfigReloader()
        let changes = ChangeCounter()
        reloader.onChange = { changes.record() }
        reloader.watch(config.loadPaths)

        // What the app does on a rejection: keep the watch it already has.
        try "not-a-real-field = 1\n".write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        try await changes.waitFor(1)
        guard case .reject = Ghostty.Config.verdict(at: config.temporaryFile.path()) else {
            Issue.record("the broken configuration was accepted")
            return
        }

        try "cursor-style = underline\n".write(to: config.temporaryFile, atomically: true, encoding: .utf8)
        try await changes.waitFor(2)
        guard case .accept = Ghostty.Config.verdict(at: config.temporaryFile.path()) else {
            Issue.record("the corrected configuration was rejected")
            return
        }
        reloader.stop()
    }
}

/// How many descriptors this process holds open for one path. Other tests
/// open and close files in the same process, so only descriptors pointing at
/// this test's own file say anything about the watcher.
private func descriptors(of watched: String) -> Int {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var count = 0
    for descriptor in Int32(0)..<Int32(getdtablesize()) where fcntl(descriptor, F_GETPATH, &buffer) >= 0 {
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path()
        if path == watched { count += 1 }
    }
    return count
}

/// Counts reload reports. The reloader delivers them on the main queue,
/// so the count is read there too.
private final class ChangeCounter: @unchecked Sendable {
    private var count = 0

    func record() {
        count += 1
    }

    var current: Int { count }

    func waitFor(_ expected: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let current = await MainActor.run { count }
            if current >= expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let current = await MainActor.run { count }
        Issue.record("expected \(expected) reloads, got \(current)")
    }
}

