import Darwin
import Foundation
import StorageKit
import Synchronization

// MyMole's privileged tool: a program inside the app that macOS runs as root
// for one request at a time, through an approved service or a one-shot prompt.
// The request travels as versioned JSON (base64 on the command line or XPC).
// XPC accepts strings only; the tool validates every decoded request and path.
// Only the direct edition carries the tool; the App Store edition has none.

/// What the app may ask the tool to do.
public enum PrivilegedRequest: Codable, Sendable, Equatable {
    /// `MaintenanceTask` raw values; only root tasks are run.
    case maintenance(tasks: [String], dryRun: Bool)
    /// System caches and logs; any path `keep` protects (itself, inside a
    /// kept item or holding one) is refused at the moment it would go.
    case removeSystem(paths: [String], keep: [String])
    /// What an uninstalled app left system-wide, checked against
    /// `SystemLeftovers` for `appID` and `ids` again. `appPath` is where the
    /// app was: only an installer record of that one app is its record.
    case removeLeftovers(paths: [String], appID: String, ids: [String], appPath: String? = nil)
    /// Exactly one verified app, moved between Applications and the active
    /// user's private Trash. No permanent deletion or arbitrary destination.
    case applicationTrash(ApplicationTrash.Request, restoring: Bool)
}

/// A request, the version of the tool it was written for and the languages
/// the app shows, best first, so the tool answers in the app's language
/// rather than root's. Without them the tool answers in English.
public struct PrivilegedEnvelope: Codable, Sendable, Equatable {
    public let version: String
    public let request: PrivilegedRequest
    public let languages: [String]?

    public init(version: String = PrivilegedTool.version, request: PrivilegedRequest,
                languages: [String]? = Bundle.main.preferredLocalizations) {
        self.version = version
        self.request = request
        self.languages = languages
    }
}

/// Where the tool's texts come from while it answers a request: the app's
/// string catalog, in the language the request names. The app itself, and
/// a tool between requests, use the main bundle as usual.
///
/// The catalog lies in the app's bundle, which the user who installed the
/// app can write, and the tool formats its texts as root. So the tool never
/// formats with a text straight from there: it reads the language's file
/// once, keeps the translations whose placeholders are exactly those of the
/// English text they stand for, and answers from a copy of those in a
/// folder only it can enter. A translation that asks for another kind of
/// value than the tool passes, which could make it read memory that isn't
/// text, is left out and its English text is used. Without a language, or
/// with nowhere private to keep the copy, it answers in English from the
/// texts compiled into it.
public enum ToolLanguage {
    private static let current = Mutex<Bundle?>(nil)

    public static var bundle: Bundle { current.withLock { $0 } ?? .main }

    /// A translation file larger than this isn't one of MyMole's.
    static let fileLimit = 8 << 20

    /// Answers `body` in the first of `languages` the catalog has.
    static func answering<T>(in languages: [String]?, base: String? = privateBase(), _ body: () -> T) -> T {
        // English has a file too: the forms its texts take for one of something.
        let language = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: languages ?? ["en"]).first
        let source = language.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
        let checked = source.flatMap { lproj in base.flatMap { CheckedTexts(from: lproj, in: $0) } }
        defer { checked?.remove() }
        current.withLock { $0 = checked?.bundle ?? english }
        defer { current.withLock { $0 = nil } }
        return body()
    }

    /// A bundle with no texts of its own, so each text is the English one
    /// compiled into the tool: a folder only root can write, or the main
    /// bundle where there's no such folder.
    static var english: Bundle {
        var st = stat()
        guard lstat("/var/empty", &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == 0, st.st_mode & 0o022 == 0,
              let empty = Bundle(path: "/var/empty")
        else { return .main }
        return empty
    }

    /// This user's own temporary folder, as macOS names it, when nobody
    /// else can enter it; the environment isn't asked.
    static func privateBase() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = Trasher.lexical(String(cString: buffer))
        return Staging.isPrivateFolder(path) ? path : nil
    }

    /// What a format takes, by the place of each value: the kind of value
    /// and its width. Nil for a format this can't vouch for: a conversion
    /// it doesn't know, a width or precision taken from the values, or
    /// numbered and unnumbered placeholders together.
    static func placeholders(of format: String) -> [Int: String]? {
        var found: [Int: String] = [:]
        var next = 1
        var numbered: Bool?
        var text = Substring(format)
        while let percent = text.firstIndex(of: "%") {
            text = text[text.index(after: percent)...]
            guard let first = text.first else { return nil }
            if first == "%" {
                text = text.dropFirst()
                continue
            }
            var digits = text.prefix { $0.isASCII && $0.isNumber }
            var position: Int?
            if !digits.isEmpty, text.dropFirst(digits.count).first == "$" {
                guard let n = Int(digits), n >= 1, n <= 64 else { return nil }
                position = n
                text = text.dropFirst(digits.count + 1)
                digits = text.prefix(0)
            }
            text = text.drop { "-+ #0'".contains($0) }
            text = text.drop { $0.isASCII && $0.isNumber }
            if text.first == "." { text = text.dropFirst().drop { $0.isASCII && $0.isNumber } }
            var length = ""
            for modifier in ["hh", "ll", "h", "l", "q", "L", "z", "t", "j"] where text.hasPrefix(modifier) {
                length = modifier
                text = text.dropFirst(modifier.count)
                break
            }
            guard let conversion = text.first else { return nil }
            text = text.dropFirst()
            let kind: String
            switch conversion {
            case "@": kind = "object"
            case "d", "i", "u", "x", "X", "o", "D", "U", "O", "c", "C":
                kind = ["ll", "l", "q", "z", "t", "j"].contains(length) || "DUO".contains(conversion) ? "integer64" : "integer32"
            case "f", "F", "e", "E", "g", "G", "a", "A": kind = length == "L" ? "longdouble" : "double"
            case "s", "S": kind = "cstring"
            case "p": kind = "pointer"
            default: return nil
            }
            guard numbered == nil || numbered == (position != nil) else { return nil }
            numbered = position != nil
            let place = position ?? next
            next += 1
            // The same value named twice must be read the same way both times.
            guard found[place] == nil || found[place] == kind else { return nil }
            found[place] = kind
        }
        return found
    }

    /// Whether `translation` may stand for `key`: it reads every value the
    /// English text reads, as the same kind, and no other.
    static func vouches(for key: String, _ translation: String) -> Bool {
        guard let wanted = placeholders(of: key), let given = placeholders(of: translation) else { return false }
        return wanted == given
    }

    private static let pluralForms: Set<String> = ["zero", "one", "two", "few", "many", "other"]

    /// Whether a text with forms by number may stand for `key`. Its format
    /// names each number it varies by as `%1$#@name@`; every form of every
    /// name, and what the format holds beside them, must read the values
    /// the English text reads, as the same kinds, and together all of them.
    static func vouches(for key: String, plural entry: [String: Any]) -> Bool {
        guard let wanted = placeholders(of: key), var format = entry["NSStringLocalizedFormatKey"] as? String else { return false }
        var read: [Int: String] = [:]
        func take(_ given: [Int: String]) -> Bool {
            for (place, kind) in given {
                guard wanted[place] == kind else { return false }
                read[place] = kind
            }
            return true
        }
        var named = Set<String>()
        while let match = format.firstMatch(of: /%(\d+)\$#@([A-Za-z0-9_]+)@/) {
            let name = String(match.2)
            guard let place = Int(match.1), let rule = entry[name] as? [String: Any], !named.contains(name),
                  rule["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType",
                  let type = rule["NSStringFormatValueTypeKey"] as? String, let kind = placeholders(of: "%" + type)?[1],
                  take([place: kind])
            else { return false }
            named.insert(name)
            var other = false
            for (form, value) in rule where form != "NSStringFormatSpecTypeKey" && form != "NSStringFormatValueTypeKey" {
                guard pluralForms.contains(form), let text = value as? String, let given = placeholders(of: text),
                      given.isEmpty || text.contains("$"), take(given)
                else { return false }
                other = other || form == "other"
            }
            guard other else { return false }
            format.replaceSubrange(match.range, with: "")
        }
        guard !named.isEmpty, entry.count == named.count + 1, !format.contains("#@"),
              let rest = placeholders(of: format), rest.isEmpty || format.contains("$"), take(rest)
        else { return false }
        return read == wanted
    }
}

/// One language's translations that passed `ToolLanguage.vouches`, copied
/// into a folder of the tool's own for the length of one request.
struct CheckedTexts {
    let bundle: Bundle
    /// How many of the file's translations were kept, and left out.
    let kept: Int
    let dropped: Int
    private let folder: String
    private let lproj: String
    private let files: [String]

    /// Nil when neither of the language's files can be read as one of
    /// MyMole's, or the copy can't be made where nobody else can reach it.
    init?(from source: String, in base: String) {
        let texts = Self.read(source + "/Localizable.strings") as? [String: String]
        let plurals = Self.read(source + "/Localizable.stringsdict") as? [String: [String: Any]]
        guard texts != nil || plurals != nil, Staging.isPrivateFolder(base) else { return nil }
        let vouched = (texts ?? [:]).filter { ToolLanguage.vouches(for: $0.key, $0.value) }
        let forms = (plurals ?? [:]).filter { ToolLanguage.vouches(for: $0.key, plural: $0.value) }
        folder = base + "/mymole-texts-" + UUID().uuidString
        lproj = folder + "/checked.lproj"
        files = [lproj + "/Localizable.strings", lproj + "/Localizable.stringsdict"]
        guard mkdir(folder, 0o700) == 0 else { return nil }
        guard mkdir(lproj, 0o700) == 0,
              vouched.isEmpty || Self.write(vouched, to: files[0]), forms.isEmpty || Self.write(forms, to: files[1]),
              let made = Bundle(path: lproj)
        else {
            Staging.removeOwn(files: files, emptyFolders: [lproj, folder])
            return nil
        }
        bundle = made
        kept = vouched.count + forms.count
        dropped = (texts?.count ?? 0) + (plurals?.count ?? 0) - kept
    }

    /// Takes the copy away: only the files and the two folders made here.
    func remove() {
        Staging.removeOwn(files: files, emptyFolders: [lproj, folder])
    }

    /// The file's translations by their English text: a plain file, opened
    /// without following a link, of a size a catalog can have.
    static func read(_ path: String) -> Any? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0, st.st_size <= ToolLanguage.fileLimit else { return nil }
        var data = Data(count: Int(st.st_size))
        let size = data.count
        let got = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, size) }
        guard got == size else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    private static func write(_ texts: [String: Any], to path: String) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: texts, format: .binary, options: 0) else { return false }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) } == data.count
    }
}

/// What the tool answers: the result of the request, or why it refused.
public enum PrivilegedReply: Codable, Sendable, Equatable {
    case reports([TaskReport])
    case removal(RemovalReport)
    case refused(String)
    case applicationTrash(ApplicationTrash.Receipt)
    case applicationTrashRefusal(ApplicationTrash.Failure)
}

public enum PrivilegedTool {
    /// Used only by the authenticated service to resolve an interrupted reply.
    /// The same lock also covers one-shot tools from another app instance.
    public static func isIdle() -> Bool {
        guard geteuid() == 0, let lock = ToolLock(path: lockPath) else { return false }
        lock.release()
        return true
    }
    /// The tool and the app ship in one bundle; a mismatch means a tool from
    /// another build was asked, which is refused.
    public static let version = "9"
    public static let name = "MyMoleHelper"

    /// The command-line argument for `envelope`.
    public static func argument(for envelope: PrivilegedEnvelope) -> String {
        (try? JSONEncoder().encode(envelope))?.base64EncodedString() ?? ""
    }

    /// Held by the copy of the tool at work. macOS starts one copy per
    /// request, so two windows or two instances of the app could otherwise
    /// remove or stage at the same time.
    public static let lockPath = "/var/run/mymole-helper.lock"

    /// Runs one request given as the tool's argument and returns the reply.
    /// Nothing runs unless the request reads, matches this version, the
    /// tool really is root and no other copy of it is at work.
    public static func handle(
        argument: String, isRoot: Bool = geteuid() == 0, runner: CommandRunner = .live, lockPath: String = lockPath
    ) -> PrivilegedReply {
        guard let data = Data(base64Encoded: argument),
            let envelope = try? JSONDecoder().decode(PrivilegedEnvelope.self, from: data)
        else { return .refused(String(localized: "The request couldn't be read.", bundle: ToolLanguage.bundle)) }
        return ToolLanguage.answering(in: envelope.languages) { answer(envelope, isRoot: isRoot, runner: runner, lockPath: lockPath) }
    }

    private static func answer(_ envelope: PrivilegedEnvelope, isRoot: Bool, runner: CommandRunner, lockPath: String) -> PrivilegedReply {
        guard envelope.version == version else {
            return .refused(String(localized: "The request was written for version \(envelope.version); this tool is version \(version).", bundle: ToolLanguage.bundle))
        }
        guard isRoot else { return .refused(String(localized: "The tool must run as root.", bundle: ToolLanguage.bundle)) }
        guard let lock = ToolLock(path: lockPath) else {
            return .refused(String(localized: "Another MyMole system task is still running, so nothing was changed.", bundle: ToolLanguage.bundle))
        }
        defer { lock.release() }
        switch envelope.request {
        case .maintenance(let tasks, let dryRun):
            let engine = MaintenanceEngine(role: .root, home: "/var/root", runner: runner)
            let wanted = tasks.compactMap(MaintenanceTask.init(rawValue:)).filter(\.needsRoot)
            return .reports(wanted.map { dryRun ? engine.check($0) : engine.run($0) })
        case .removeSystem(let paths, let keep):
            return .removal(SystemCleanRules.remove(paths, keep: CleanKeepList(paths: Set(keep))))
        case .removeLeftovers(let paths, let appID, let ids, let appPath):
            return .removal(SystemLeftovers.remove(paths, appID: appID, ids: ids, appPath: appPath, runner: runner))
        case .applicationTrash(let request, let restoring):
            do { return .applicationTrash(try ApplicationTrash.move(request, restoring: restoring)) }
            catch let failure as ApplicationTrash.Failure { return .applicationTrashRefusal(failure) }
            catch { return .refused(error.localizedDescription) }
        }
    }

    /// The reply as the tool prints it: one line of JSON.
    public static func output(_ reply: PrivilegedReply) -> String {
        (try? JSONEncoder().encode(reply)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The reply from what the tool printed.
    public static func reply(from output: String) -> PrivilegedReply? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONDecoder().decode(PrivilegedReply.self, from: Data(line.utf8))
    }
}

/// An exclusive lock on a file only the tool's own user may own, held for
/// one request. Released when the tool ends, however it ends.
struct ToolLock {
    private let fd: Int32

    /// Nil when another copy holds it, or the file isn't a plain file of
    /// this user's that only they can write.
    init?(path: String) {
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1,
            st.st_mode & 0o022 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0
        else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
