import Foundation
import Testing

@testable import StorageKit

/// System Data measured place by place, in folders of the test's own.
@Suite struct SystemDataTests {
    private func place(_ id: String, _ paths: [String]) -> SystemData.Place {
        SystemData.Place(id: id, title: id, detail: "", paths: paths, remedy: .macOS)
    }

    @Test func aPlaceInsideAnotherIsCountedOnceAndTheLargestFilesAreListed() throws {
        let box = try Sandbox()
        try box.file("Support/app/big.bin", bytes: 3 << 20)
        try box.file("Support/app/small.bin", bytes: 2 << 20)
        try box.file("Support/Backup/device.bin", bytes: 4 << 20)
        let support = place("support", [box.path + "/Support"]), backups = place("backups", [box.path + "/Support/Backup"])
        let measured = SystemData.measure([support, backups], workers: 1, largest: 1)
        let s = try #require(measured.first { $0.id == "support" }), b = try #require(measured.first { $0.id == "backups" })
        #expect(s.largest.map(\.path) == [box.path + "/Support/app/big.bin"])
        #expect(b.largest.map(\.path) == [box.path + "/Support/Backup/device.bin"])
        let alone = SystemData.measure([support], workers: 1)
        #expect(try #require(s.bytes) < #require(alone.first?.bytes))
        #expect(s.bytes! + b.bytes! == alone.first!.bytes!)
        #expect(!s.partial && !b.partial)
    }

    @Test func aMissingFolderIsNothingAndThePlacesAreThisUsers() throws {
        let box = try Sandbox()
        let gone = SystemData.measure([place("gone", [box.path + "/none"])], workers: 1)
        #expect(gone.first?.bytes == nil && gone.first?.partial == false)
        let places = SystemData.places(home: "/synthetic/home", temporary: "/private/var/folders/xx/yy/T/")
        #expect(places.first { $0.id == "temporary" }?.paths == ["/private/var/folders/xx/yy/T", "/private/var/folders/xx/yy/C"])
        #expect(places.first { $0.id == "caches" }?.remedy == .deepClean)
        #expect(Set(places.map(\.id)).count == places.count)
    }
}
