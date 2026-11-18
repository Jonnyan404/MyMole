import Dispatch
import Testing

@testable import StorageKit

@Suite struct SameSizeFilesTests {
    @Test func aQuickAnswerIsUsed() {
        #expect(SameSizeFiles.answer(within: .seconds(30)) { ["/a"] } == ["/a"])
    }

    /// A Spotlight lookup that never returns must not hold up the search:
    /// after the limit it finds nothing, and the stalled lookup is left on
    /// its own thread.
    @Test func aStalledLookupFindsNothingAfterTheLimit() {
        let stalled = DispatchSemaphore(value: 0)
        defer { stalled.signal() }
        let start = ContinuousClock.now
        let found = SameSizeFiles.answer(within: .milliseconds(300)) { stalled.wait(); return ["/late"] }
        #expect(found == nil)
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func aStoppedSearchStopsWaiting() {
        let stalled = DispatchSemaphore(value: 0)
        defer { stalled.signal() }
        let start = ContinuousClock.now
        let found = SameSizeFiles.answer(within: .seconds(600), stop: { true }) { stalled.wait(); return ["/late"] }
        #expect(found == nil)
        #expect(ContinuousClock.now - start < .seconds(20))
    }
}
