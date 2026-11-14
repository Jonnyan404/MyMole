import FileProvider
import Foundation

// The test cloud's app: owns the File Provider extension and its domains.
// Run from `scripts/cloud-tests.sh`:
//   seed <domain> <folder>        the domain's server becomes a copy of <folder>
//   add <domain> <display name>   adds the domain; macOS shows it in ~/Library/CloudStorage
//   path <domain>                 prints the domain's folder there
//   evict <domain> <path>         makes a downloaded item cloud-only again
//   fetches                       prints the log of content requests
//   clear-log                     empties it
//   remove-all                    removes every domain and the server's files

let group = Bundle.main.object(forInfoDictionaryKey: "MyMoleCloudGroup") as! String
let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)!
let log = container.appending(path: "fetches.log")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func domain(_ id: String, _ name: String? = nil) -> NSFileProviderDomain {
    NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: name ?? id)
}

func manager(_ id: String) async -> NSFileProviderManager {
    let domains = (try? await NSFileProviderManager.domains()) ?? []
    guard let found = domains.first(where: { $0.identifier.rawValue == id }), let m = NSFileProviderManager(for: found)
    else { fail("No domain \(id)") }
    return m
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("seed", 3):
    let server = container.appending(path: "server").appending(path: args[1])
    try? FileManager.default.removeItem(at: server)
    try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: server)
case ("add", 3):
    try await NSFileProviderManager.add(domain(args[1], args[2]))
    try await NSFileProviderManager(for: domain(args[1], args[2]))?.signalEnumerator(for: .rootContainer)
case ("path", 2):
    print(try await manager(args[1]).getUserVisibleURL(for: .rootContainer).path)
case ("evict", 3):
    try await manager(args[1]).evictItem(identifier: NSFileProviderItemIdentifier(args[2]))
case ("fetches", 1):
    print((try? String(contentsOf: log, encoding: .utf8)) ?? "", terminator: "")
case ("clear-log", 1):
    try? FileManager.default.removeItem(at: log)
case ("remove-all", 1):
    try await NSFileProviderManager.removeAllDomains()
    try? FileManager.default.removeItem(at: container.appending(path: "server"))
    try? FileManager.default.removeItem(at: log)
default:
    fail("Usage: seed|add|path|evict|fetches|clear-log|remove-all")
}
