import StorageKit
import Testing

@testable import MyMole

/// Files moved to the Trash still take their room on the disk, so disk use
/// stays the same until the Trash is emptied. The Dashboard says so.
@Suite struct DashboardTrashNoteTests {
    @Test func aTrashWorthEmptyingIsNamedWithWhatItFrees() throws {
        let note = try #require(DashboardView.trashNote(frees: 3 * 1_073_741_824))
        #expect(note.contains(ByteSize.format(3 * 1_073_741_824)))
    }

    @Test func anEmptyUnreadOrTinyTrashSaysNothing() {
        #expect(DashboardView.trashNote(frees: nil) == nil)
        #expect(DashboardView.trashNote(frees: 0) == nil)
        #expect(DashboardView.trashNote(frees: DashboardView.trashNoteMinimum - 1) == nil)
        #expect(DashboardView.trashNote(frees: DashboardView.trashNoteMinimum) != nil)
    }
}
