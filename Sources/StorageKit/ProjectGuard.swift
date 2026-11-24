import Darwin
import Foundation

// What a project folder may hold that must never go to the Trash with it:
// another Git repository, key files a project deploys with, files the
// project's own Git tracks, or an agent worktree's uncommitted work. Checked
// right before a move; anything that can't be checked stays.

public enum ProjectGuard {
    /// Key files, by name and extension.
    static let keyNames: Set<String> = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    static let keyExtensions: Set<String> = ["pem", "key", "p12", "pfx", "p8", "jks", "keystore"]

    /// Third-party code: test keys shipped inside packages aren't the project's.
    static let thirdParty: Set<String> = ["node_modules", "Pods", ".venv", "venv", "site-packages", "vendor"]

    /// Where Git may be installed. `/usr/bin/git` is left out: without the
    /// developer tools it asks the user to install them.
    static let gitLocations = [
        "/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/opt/homebrew/bin/git", "/usr/local/bin/git",
    ]

    /// Why `path` must stay, or nil when it may go. `worktree` is for agent
    /// worktrees, which are Git checkouts of their own: their own `.git` is
    /// expected, but key files and other repositories inside still keep them,
    /// even when Git ignores those files and reports the tree clean.
    public static func reason(
        for path: String, project: String, worktree: Bool = false, runner: CommandRunner = .processes(timeLimit: 30)
    ) -> String? {
        if let r = scan(path, ownGit: worktree, runner: runner) { return r }
        if worktree { return uncommitted(path, runner: runner) }
        return tracked(path, project: project, runner: runner)
    }

    /// As `reason(for:)` for files side by side in one folder of a project,
    /// by path: Git is asked about them together, not once for each.
    public static func reasons(
        forFiles paths: [String], project: String, runner: CommandRunner = .processes(timeLimit: 30)
    ) -> [String: String] {
        var held: [String: String] = [:]
        var files: [String: [String]] = [:]
        for path in paths {
            if ProjectRules.isRealFolder(path) {
                held[path] = reason(for: path, project: project, runner: runner)
            } else if let why = scan(path, runner: runner) {
                held[path] = why
            } else {
                files[(path as NSString).deletingLastPathComponent, default: []].append(path)
            }
        }
        for siblings in files.values { held.merge(tracked(siblings: siblings, project: project, runner: runner)) { a, _ in a } }
        return held
    }

    /// Files one Git command is asked about: far below the argument limit.
    static let filesPerCommand = 400

    /// Which of `siblings`, files in one folder, the enclosing repository
    /// tracks, or why none of them could be checked.
    private static func tracked(siblings: [String], project: String, runner: CommandRunner) -> [String: String] {
        guard let first = siblings.first, let repo = enclosingRepository(of: first, within: project) else { return [:] }
        func all(_ why: String) -> [String: String] { Dictionary(siblings.map { ($0, why) }, uniquingKeysWith: { a, _ in a }) }
        guard let git = git(runner) else { return all(String(localized: "Git isn't installed, so tracked files couldn't be checked.")) }
        if let why = untrusted(repo) { return all(why) }
        var held: [String: String] = [:]
        for start in stride(from: 0, to: siblings.count, by: filesPerCommand) {
            let some = siblings[start..<min(siblings.count, start + filesPerCommand)]
            let names = some.map { String($0.dropFirst(repo.count + 1)) }
            let r = runner.run(git, safety + ["--literal-pathspecs", "-C", repo, "ls-files", "-z", "--"] + names)
            guard r.code == 0 else {
                for path in some { held[path] = String(localized: "Git couldn't check it for tracked files.") }
                continue
            }
            // Each tracked file ends in a NUL; a warning before the first doesn't hide it.
            guard r.output.contains("\0") else { continue }
            let listed = Set(r.output.split(separator: "\0").map(String.init))
            let hits = some.filter { listed.contains(String($0.dropFirst(repo.count + 1))) }
            for path in hits.count == r.output.filter({ $0 == "\0" }).count ? hits : Array(some) {
                held[path] = String(localized: "Holds files Git tracks.")
            }
        }
        return held
    }

    /// A nested repository or key file inside, without following links.
    /// `ownGit` lets the `.git` right inside `path` be, as a worktree's own.
    /// A package SwiftPM or Xcode checked out, and can again, is third-party
    /// code once nobody has worked in it.
    static func scan(_ path: String, ownGit: Bool = false, runner: CommandRunner) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return String(localized: "It's gone or can't be read.") }
        if (path as NSString).lastPathComponent == ".git" { return String(localized: "It's a Git repository.") }
        guard st.st_mode & S_IFMT == S_IFDIR else { return isKey((path as NSString).lastPathComponent) ? String(localized: "It's a key file.") : nil }
        var stack: [(String, Bool)] = [(path, thirdParty.contains((path as NSString).lastPathComponent))]
        while let (dir, inThirdParty) = stack.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                return String(localized: "A folder inside can't be read, so it couldn't be checked.")
            }
            var theirs = inThirdParty
            if names.contains(".git"), !(ownGit && dir == path) {
                guard isUntouchedCheckout(dir, runner: runner) else { return String(localized: "Holds a Git repository.") }
                theirs = true
            }
            for name in names where name != ".git" {
                let p = dir + "/" + name
                guard lstat(p, &st) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR {
                    stack.append((p, theirs || thirdParty.contains(name)))
                } else if !theirs, isKey(name) {
                    return String(localized: "Holds key files.")
                }
            }
        }
        return nil
    }

    /// Key files, and local secret files such as `.env`, which Git usually
    /// ignores and so never shows as uncommitted.
    static func isKey(_ name: String) -> Bool {
        keyNames.contains(name) || keyExtensions.contains((name as NSString).pathExtension.lowercased())
            || ((name == ".env" || name.hasPrefix(".env.")) && !envTemplates.contains(name))
    }

    /// Committed examples of a `.env` file, without secrets.
    static let envTemplates: Set<String> = [".env.example", ".env.sample", ".env.template", ".env.dist"]

    static func git(_ runner: CommandRunner) -> String? { gitLocations.first(where: runner.exists) }

    // MARK: Package checkouts

    /// Whether the repository at `dir` is a package SwiftPM or Xcode checked
    /// out and nobody has worked in: their own list names it and its
    /// revision, Git is at exactly that revision and holds no object of its
    /// own, so no commit, stash or staged change, and every file is as it
    /// was checked out with none beside them, ignored ones included. Git's
    /// index is enough for that: the objects are in a store next to
    /// `checkouts`, which may be gone. What can't be told counts as touched.
    static func isUntouchedCheckout(_ dir: String, runner: CommandRunner) -> Bool {
        let checkouts = (dir as NSString).deletingLastPathComponent
        let store = dir + "/.git"
        guard (checkouts as NSString).lastPathComponent == "checkouts",
              let revision = checkedOut((dir as NSString).lastPathComponent, in: (checkouts as NSString).deletingLastPathComponent),
              ProjectRules.isRealFolder(store),
              let head = smallFile(store + "/HEAD", limit: 1_024).flatMap({ String(data: $0, encoding: .utf8) }),
              head.trimmingCharacters(in: .whitespacesAndNewlines) == revision,
              holdsNoObjects(store),
              !["modules", "worktrees", "shallow"].contains(where: { exists(store + "/" + $0) }),
              untrusted(dir) == nil, let git = git(runner)
        else { return false }
        // The folder and its own files only, whatever its settings name.
        let asking = safety + ["-c", "core.ignoreStat=false", "-c", "core.fileMode=true", "--no-optional-locks", "-C", dir, "--git-dir=.git", "--work-tree=."]
        func ask(_ arguments: [String]) -> String? {
            let r = runner.run(git, asking + arguments)
            return r.code == 0 ? r.output : nil
        }
        // Each file in an answer ends in a NUL; warnings don't.
        guard let listed = ask(["ls-files", "-z", "-v"]), allChecked(listed),
              let changed = ask(["diff", "--raw", "-z", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none"]), !changed.contains("\0"),
              let beside = ask(["ls-files", "-z", "--others"]), !beside.contains("\0")
        else { return false }
        return true
    }

    /// The revision SwiftPM's or Xcode's own list in `base` gives for the
    /// package it checked out as `name`.
    static func checkedOut(_ name: String, in base: String) -> String? {
        guard let data = smallFile(base + "/workspace-state.json", limit: 8 << 20),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = root["object"] as? [String: Any],
              let dependencies = object["dependencies"] as? [[String: Any]]
        else { return nil }
        let named = dependencies.filter { $0["subpath"] as? String == name }
        guard named.count == 1, let state = named[0]["state"] as? [String: Any], state["name"] as? String == "sourceControlCheckout",
              let checkout = state["checkoutState"] as? [String: Any], let revision = checkout["revision"] as? String,
              revision.count >= 40, revision.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { return nil }
        return revision
    }

    /// A shared clone with nothing written to it: only the note of where
    /// the objects are.
    static func holdsNoObjects(_ store: String) -> Bool {
        guard ProjectRules.isRealFolder(store + "/objects"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: store + "/objects") else { return false }
        var shared = false
        for name in names {
            let dir = store + "/objects/" + name
            guard ProjectRules.isRealFolder(dir), let inside = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
            if name == "info" {
                guard inside == ["alternates"] else { return false }
                shared = true
            } else if !inside.isEmpty {
                return false
            }
        }
        return shared
    }

    /// Whether `ls-files -v` listed files and Git compares every one of
    /// them: none is marked to be taken as unchanged or left out.
    static func allChecked(_ output: String) -> Bool {
        var records = output.components(separatedBy: "\0")
        // A warning after the last file, or nothing.
        records.removeLast()
        guard let first = records.first else { return false }
        // A warning comes before the first file, on lines of its own.
        records[0] = first.components(separatedBy: "\n").last ?? ""
        return records.allSatisfy { $0.hasPrefix("H ") }
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 || errno != ENOENT
    }

    /// A plain file of at most `limit` bytes, never through a link.
    private static func smallFile(_ path: String, limit: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= limit else { return nil }
        let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1)
        return data.flatMap { $0.count <= limit ? $0 : nil }
    }

    /// Put before every command: a repository's settings can't start an
    /// fsmonitor program while Git reads the index.
    static let safety = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    /// The setting files Git reads for the repository at `dir`, a checkout
    /// or a worktree whose `.git` is a file naming its folder. Nil when the
    /// `.git` can't be made sense of.
    static func configFiles(of dir: String) -> [String]? {
        let dotGit = dir + "/.git"
        var st = stat()
        guard lstat(dotGit, &st) == 0 else { return nil }
        var gitDir = dotGit
        if st.st_mode & S_IFMT == S_IFREG {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
            let named = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = named.hasPrefix("/") ? named : dir + "/" + named
        } else if st.st_mode & S_IFMT != S_IFDIR {
            return nil
        }
        var files = [gitDir + "/config", gitDir + "/config.worktree"]
        if let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            let commonDir = c.hasPrefix("/") ? c : gitDir + "/" + c
            files += [commonDir + "/config", commonDir + "/config.worktree"]
        }
        return files
    }

    /// Whether any of `files` makes Git run a program while it reads the
    /// working tree: a content filter, or an include that could bring one
    /// in. A file that's there but can't be read counts as one.
    static func runsPrograms(_ files: [String]) -> Bool {
        files.contains { file in
            guard FileManager.default.fileExists(atPath: file) else { return false }
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return true }
            return text.lowercased().split(whereSeparator: \.isNewline).contains { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                return l.hasPrefix("[filter") || l.hasPrefix("[include")
            }
        }
    }

    /// Why Git won't be asked about `dir`, if it won't.
    static func untrusted(_ dir: String) -> String? {
        guard let files = configFiles(of: dir) else { return String(localized: "Its Git folder couldn't be read, so it wasn't checked.") }
        return runsPrograms(files) ? String(localized: "Its Git settings could run programs, so it wasn't checked.") : nil
    }

    /// Files under `path` that the enclosing repository tracks.
    static func tracked(_ path: String, project: String, runner: CommandRunner) -> String? {
        guard let repo = enclosingRepository(of: path, within: project) else { return nil }
        guard let git = git(runner) else { return String(localized: "Git isn't installed, so tracked files couldn't be checked.") }
        if let why = untrusted(repo) { return why }
        let rel = String(path.dropFirst(repo.count + 1))
        let r = runner.run(git, safety + ["-C", repo, "ls-files", "-z", "--", rel])
        guard r.code == 0 else { return String(localized: "Git couldn't check it for tracked files.") }
        // Each tracked file ends in a NUL; warnings on the same output don't.
        return r.output.contains("\0") ? String(localized: "Holds files Git tracks.") : nil
    }

    /// The nearest folder above `path`, up to `project`, with a `.git` in it.
    static func enclosingRepository(of path: String, within project: String) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
            if dir == project { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func uncommitted(_ path: String, runner: CommandRunner) -> String? {
        guard let git = git(runner) else { return String(localized: "Git isn't installed, so uncommitted work couldn't be checked.") }
        if let why = untrusted(path) { return why }
        let r = runner.run(git, safety + ["--no-optional-locks", "-C", path, "status", "--porcelain", "-z", "--untracked-files=normal"])
        guard r.code == 0 else { return String(localized: "Git couldn't check it for uncommitted work.") }
        return r.output.contains("\0") ? String(localized: "Has uncommitted work.") : nil
    }
}
