import FileProvider
import Foundation
import UniformTypeIdentifiers

/// A cloud service for MyMole's tests, built the way Dropbox, Google Drive,
/// OneDrive and Proton Drive are on macOS: a replicated File Provider. Its
/// "server" is a folder in the app group's container, one per domain, so
/// nothing goes over the network. Every request for a file's content is
/// written to `fetches.log`: the tests read it to tell what made macOS
/// download a file that was only in the cloud.
enum Server {
    static let group = Bundle.main.object(forInfoDictionaryKey: "MyMoleCloudGroup") as! String

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)!
    }

    static func root(of domain: NSFileProviderDomainIdentifier) -> URL {
        container.appending(path: "server", directoryHint: .isDirectory).appending(path: domain.rawValue, directoryHint: .isDirectory)
    }

    static func url(_ id: NSFileProviderItemIdentifier, in domain: NSFileProviderDomainIdentifier) -> URL {
        id == .rootContainer ? root(of: domain) : root(of: domain).appending(path: id.rawValue)
    }

    static func log(_ line: String) {
        let url = container.appending(path: "fetches.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// One file or folder on the server, known by its path below the domain's root.
final class Item: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    init?(_ id: NSFileProviderItemIdentifier, in domain: NSFileProviderDomainIdentifier) {
        let url = Server.url(id, in: domain)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])
        else { return nil }
        itemIdentifier = id
        if id == .rootContainer {
            parentItemIdentifier = .rootContainer
            filename = domain.rawValue
        } else {
            let parent = (id.rawValue as NSString).deletingLastPathComponent
            parentItemIdentifier = parent.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(parent)
            filename = (id.rawValue as NSString).lastPathComponent
        }
        let folder = values.isDirectory == true
        contentType = folder ? .folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
        documentSize = folder ? nil : NSNumber(value: values.fileSize ?? 0)
        creationDate = values.creationDate
        contentModificationDate = values.contentModificationDate
        let stamp = Data("\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values.fileSize ?? 0)".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: stamp, metadataVersion: stamp)
    }

    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsContentEnumerating, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsAddingSubItems]
    }
}

@objc(MyMoleCloudProvider)
final class Provider: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let item = Item(identifier, in: domain.identifier) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        Server.log("fetch\t\(domain.identifier.rawValue)\t\(itemIdentifier.rawValue)")
        guard let item = Item(itemIdentifier, in: domain.identifier),
              let manager = NSFileProviderManager(for: domain),
              let temporary = try? manager.temporaryDirectoryURL()
        else {
            completionHandler(nil, nil, NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue))
            return Progress()
        }
        let copy = temporary.appending(path: UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: Server.url(itemIdentifier, in: domain.identifier), to: copy)
            completionHandler(copy, item, nil)
        } catch {
            completionHandler(nil, nil, error)
        }
        return Progress()
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let parent = itemTemplate.parentItemIdentifier == .rootContainer ? "" : itemTemplate.parentItemIdentifier.rawValue + "/"
        let id = NSFileProviderItemIdentifier(parent + itemTemplate.filename)
        let target = Server.url(id, in: domain.identifier)
        Server.log("create\t\(domain.identifier.rawValue)\t\(id.rawValue)")
        do {
            if itemTemplate.contentType == .folder {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else if let url {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
            } else {
                FileManager.default.createFile(atPath: target.path, contents: nil)
            }
            completionHandler(Item(id, in: domain.identifier), [], false, nil)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        Server.log("modify\t\(domain.identifier.rawValue)\t\(item.itemIdentifier.rawValue)")
        var id = item.itemIdentifier
        do {
            if changedFields.contains(.contents), let newContents {
                let target = Server.url(id, in: domain.identifier)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: newContents, to: target)
            }
            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let parent = item.parentItemIdentifier == .rootContainer ? "" : item.parentItemIdentifier.rawValue + "/"
                let moved = NSFileProviderItemIdentifier(parent + item.filename)
                try FileManager.default.moveItem(at: Server.url(id, in: domain.identifier), to: Server.url(moved, in: domain.identifier))
                id = moved
            }
            completionHandler(Item(id, in: domain.identifier), [], false, nil)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        Server.log("delete\t\(domain.identifier.rawValue)\t\(identifier.rawValue)")
        do {
            try FileManager.default.removeItem(at: Server.url(identifier, in: domain.identifier))
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        Enumerator(container: containerItemIdentifier, domain: domain.identifier)
    }
}

/// A folder's children, all in one page; the working set and the trash are
/// empty, and nothing changes behind the system's back.
final class Enumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier
    let domain: NSFileProviderDomainIdentifier

    init(container: NSFileProviderItemIdentifier, domain: NSFileProviderDomainIdentifier) {
        self.container = container
        self.domain = domain
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard container != .workingSet, container != .trashContainer else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let folder = Server.url(container, in: domain)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let prefix = container == .rootContainer ? "" : container.rawValue + "/"
        let items = names.compactMap { Item(NSFileProviderItemIdentifier(prefix + $0), in: domain) }
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("1".utf8)))
    }
}
