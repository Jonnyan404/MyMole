import Foundation
import Testing

@testable import StorageKit

/// A package SwiftPM or Xcode checked out goes with its build output only
/// when nobody has worked in it. Git is never run: a fake answers for it.
@Suite struct PackageCheckoutTests {
    private static let revision = String(repeating: "a1b2c3d4", count: 5)

    private final class FakeGit: @unchecked Sendable {
        var files = "H Package.swift\0H test.pem\0"
        var changed = ""
        var beside = ""
        var tracked = ""
        var code: Int32 = 0
        var calls: [[String]] = []

        var runner: CommandRunner {
            CommandRunner(run: { _, args in
                self.calls.append(args)
                if args.contains("-v") { return (self.code, self.files) }
                if args.contains("--others") { return (self.code, self.beside) }
                if args.contains("diff") { return (self.code, self.changed) }
                return (0, self.tracked)
            }, exists: { $0 == ProjectGuard.gitLocations[0] })
        }
    }

    private struct Package {
        let box: Sandbox
        var project: String { box.path + "/app" }
        var build: String { project + "/.build" }
        var checkout: String { build + "/checkouts/Dep" }
        let git = FakeGit()

        init() throws {
            box = try Sandbox()
            try box.file("app/.build/out/x.o", bytes: 100)
            try box.file("app/.build/checkouts/Dep/Package.swift", bytes: 100)
            try box.file("app/.build/checkouts/Dep/test.pem", bytes: 100)
            try box.folder("app/.build/checkouts/Dep/.git/objects/pack")
            try write("[core]\n\tbare = false\n", ".git/config")
            try write(PackageCheckoutTests.revision + "\n", ".git/HEAD")
            try box.folder("app/.build/checkouts/Dep/.git/objects/info")
            try write("/synthetic/repositories/Dep/objects\n", ".git/objects/info/alternates")
            try list()
        }

        func write(_ text: String, _ name: String) throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: checkout + "/" + name))
        }

        func list(_ state: String = "sourceControlCheckout", revision: String = PackageCheckoutTests.revision, name: String = "Dep", times: Int = 1) throws {
            let one = #"{"packageRef":{"identity":"dep"},"state":{"checkoutState":{"revision":"\#(revision)"},"name":"\#(state)"},"subpath":"\#(name)"}"#
            let text = #"{"object":{"artifacts":[],"dependencies":[\#(Array(repeating: one, count: times).joined(separator: ","))]},"version":7}"#
            try Data(text.utf8).write(to: URL(fileURLWithPath: build + "/workspace-state.json"))
        }

        var reason: String? { ProjectGuard.reason(for: build, project: project, runner: git.runner) }
    }

    private let held = "Holds a Git repository."

    @Test func anUntouchedCheckoutGoesWithTheBuildOutputTestKeysAndAll() throws {
        let p = try Package()
        #expect(p.reason == nil)
        #expect(ProjectGuard.reason(for: p.checkout, project: p.project, runner: p.git.runner) == nil)
        #expect(ProjectGuard.reason(for: p.build + "/checkouts", project: p.project, runner: p.git.runner) == nil)
        // Only the checkout itself is asked about, and nothing is written.
        for call in p.git.calls {
            #expect(call.starts(with: ProjectGuard.safety) && call.contains("--no-optional-locks"))
            #expect(call.contains("--git-dir=.git") && call.contains("--work-tree=.") && call.contains(p.checkout))
        }
        // A warning about a missing object store doesn't hide the answer.
        p.git.files = "error: unable to normalize alternate object path\n" + p.git.files
        #expect(p.reason == nil)
    }

    @Test func xcodesCheckoutsAreReadTheSameWay() throws {
        let p = try Package()
        let packages = p.box.path + "/DerivedData/App/SourcePackages"
        try FileManager.default.createDirectory(atPath: p.box.path + "/DerivedData/App", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: p.build, toPath: packages)
        #expect(ProjectGuard.reason(for: p.box.path + "/DerivedData/App", project: p.project, runner: p.git.runner) == nil)
    }

    @Test func anyWorkInItKeepsIt() throws {
        let p = try Package()
        p.git.changed = ":100644 100644 a b M\0Package.swift\0"
        #expect(p.reason == held)
        p.git.changed = ""
        p.git.beside = ".env\0"
        #expect(p.reason == held)
        p.git.beside = ""
        for files in ["h Package.swift\0H test.pem\0", "H Package.swift\0S test.pem\0", "H a\0h b\nH c\0", "", "warning only\n"] {
            p.git.files = files
            #expect(p.reason == held, "\(files)")
        }
        p.git.files = "H Package.swift\0"
        p.git.code = 128
        #expect(p.reason == held)
        p.git.code = 0
        #expect(p.reason == nil)
    }

    @Test func commitsStashesAndStagedFilesKeepIt() throws {
        for object in [".git/objects/ab/cdef", ".git/objects/pack/pack-1.pack", ".git/objects/info/commit-graph", ".git/objects/loose"] {
            let p = try Package()
            try p.box.file("app/.build/checkouts/Dep/" + object, bytes: 10)
            #expect(p.reason == held, "\(object)")
            #expect(p.git.calls.isEmpty)
        }
        for name in ["modules", "worktrees"] {
            let p = try Package()
            try p.box.folder("app/.build/checkouts/Dep/.git/" + name)
            #expect(p.reason == held, "\(name)")
        }
        // Not a shared clone: what it holds isn't known to be elsewhere.
        let p = try Package()
        try FileManager.default.removeItem(atPath: p.checkout + "/.git/objects/info/alternates")
        #expect(p.reason == held)
    }

    @Test func onlyTheListedCheckoutAtItsRevisionGoes() throws {
        for head in ["ref: refs/heads/main\n", String(repeating: "b", count: 40) + "\n", ""] {
            let p = try Package()
            try p.write(head, ".git/HEAD")
            #expect(p.reason == held, "\(head)")
        }
        let p = try Package()
        try p.list("edited")
        #expect(p.reason == held)
        try p.list(name: "Other")
        #expect(p.reason == held)
        try p.list(times: 2)
        #expect(p.reason == held)
        try p.list(revision: "main")
        #expect(p.reason == held)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: p.build + "/workspace-state.json"))
        #expect(p.reason == held)
        try FileManager.default.removeItem(atPath: p.build + "/workspace-state.json")
        #expect(p.reason == held)
        #expect(p.git.calls.isEmpty)
    }

    @Test func linksAndSettingsThatRunProgramsKeepIt() throws {
        let p = try Package()
        try p.write("[filter \"x\"]\n\tclean = touch /tmp/owned\n", ".git/config")
        #expect(p.reason == held && p.git.calls.isEmpty)
        let linked = try Package()
        let list = linked.build + "/workspace-state.json"
        try FileManager.default.moveItem(atPath: list, toPath: linked.box.path + "/elsewhere.json")
        try FileManager.default.createSymbolicLink(atPath: list, withDestinationPath: linked.box.path + "/elsewhere.json")
        #expect(linked.reason == held)
        let store = try Package()
        try FileManager.default.moveItem(atPath: store.checkout + "/.git", toPath: store.box.path + "/store")
        try FileManager.default.createSymbolicLink(atPath: store.checkout + "/.git", withDestinationPath: store.box.path + "/store")
        #expect(store.reason == held)
    }

    @Test func otherRepositoriesAndKeysInTheBuildOutputStillKeepIt() throws {
        let beside = try Package()
        try beside.box.file("app/.build/mine/.git/HEAD", bytes: 10)
        #expect(beside.reason == held)
        let inside = try Package()
        try inside.box.file("app/.build/checkouts/Dep/vendor/lib/.git/HEAD", bytes: 10)
        #expect(inside.reason == held)
        let key = try Package()
        try key.box.file("app/.build/deploy/server.pem", bytes: 10)
        #expect(key.reason == "Holds key files.")
        // No Git to ask: it can't be told, so it stays.
        let p = try Package()
        #expect(ProjectGuard.reason(for: p.build, project: p.project, runner: CommandRunner(run: { _, _ in (0, "") }, exists: { _ in false })) == held)
    }

    @Test func filesSideBySideAreAskedAboutTogether() throws {
        let box = try Sandbox()
        try box.file("app/.git/HEAD", bytes: 10)
        let project = box.path + "/app"
        let names = (0..<900).map { "f\($0)" }
        for name in names + ["server.pem", "[x]*.txt"] { try box.file("app/out/" + name, bytes: 1) }
        let git = FakeGit()
        let paths = (names + ["server.pem", "[x]*.txt"]).map { project + "/out/" + $0 }
        #expect(ProjectGuard.reasons(forFiles: paths, project: project, runner: git.runner) == [project + "/out/server.pem": "It's a key file."])
        #expect(git.calls.count == 3 && git.calls.allSatisfy { $0.contains("--literal-pathspecs") && $0.contains(project) })
        #expect(git.calls.flatMap { $0 }.filter { $0.hasPrefix("out/") }.count == 901)
        // Tracked ones stay, the others may go.
        git.tracked = "out/f2\0"
        let held = ProjectGuard.reasons(forFiles: [project + "/out/f1", project + "/out/f2"], project: project, runner: git.runner)
        #expect(held == [project + "/out/f2": "Holds files Git tracks."])
        // An answer that can't be matched to the files keeps them all.
        git.tracked = "warning\nout/f2\0"
        #expect(ProjectGuard.reasons(forFiles: [project + "/out/f1", project + "/out/f2"], project: project, runner: git.runner).count == 2)
        // A folder where a file was is checked as a folder, and a gone file stays out.
        try box.file("app/out/now/.git/HEAD", bytes: 1)
        git.tracked = ""
        let odd = ProjectGuard.reasons(forFiles: [project + "/out/now", project + "/out/gone"], project: project, runner: git.runner)
        #expect(odd[project + "/out/now"] == "Holds a Git repository." && odd[project + "/out/gone"] == "It's gone or can't be read.")
        // Git that fails or is missing keeps them.
        #expect(ProjectGuard.reasons(forFiles: [project + "/out/f1"], project: project,
                                     runner: CommandRunner(run: { _, _ in (128, "") }, exists: { $0 == ProjectGuard.gitLocations[0] })).count == 1)
    }

    @Test func theSmallFilesOfAFolderAreItsPlainFilesUnderOneMegabyte() throws {
        let box = try Sandbox()
        for name in ["a", "b.txt", ".hidden"] { try box.file("f/" + name, bytes: 5_000) }
        try box.file("f/large", bytes: 2 << 20)
        try box.file("f/sub/inner", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: box.path + "/f/link", withDestinationPath: box.path + "/f/a")
        let found = try #require(SmallFileList.read(in: box.path + "/f"))
        #expect(Set(found.map(\.path)) == Set(["a", "b.txt", ".hidden"].map { box.path + "/f/" + $0 }))
        #expect(found.allSatisfy { $0.isDirectory == false && $0.bytes >= 4_096 })
        #expect(SmallFileList.read(in: box.path + "/none") == nil)
        try FileManager.default.createSymbolicLink(atPath: box.path + "/linked", withDestinationPath: box.path + "/f")
        #expect(SmallFileList.read(in: box.path + "/linked") == nil)
    }
}
