import XCTest
@testable import Shiyi

final class CopySequenceTests: XCTestCase {
    func testOnlyFreshCopyInSameAppWithinWindowIsAccepted() {
        var sequence = CopySequence()
        sequence.arm(changeCount: 10, pid: 123, now: 100)
        XCTAssertTrue(sequence.accepts(changeCount: 11, pid: 123, now: 102))
        XCTAssertFalse(sequence.accepts(changeCount: 10, pid: 123, now: 102))
        XCTAssertFalse(sequence.accepts(changeCount: 11, pid: 456, now: 102))
        XCTAssertFalse(sequence.accepts(changeCount: 11, pid: 123, now: 103.01))
    }
    func testCancellationAndNewCopyReplaceArmedState() {
        var sequence = CopySequence()
        XCTAssertFalse(sequence.accepts(changeCount: 1, pid: 123, now: 0))
        sequence.arm(changeCount: 10, pid: 123, now: 100)
        sequence.cancel()
        XCTAssertFalse(sequence.accepts(changeCount: 11, pid: 123, now: 101))
        sequence.arm(changeCount: 11, pid: 456, now: 102)
        XCTAssertFalse(sequence.accepts(changeCount: 11, pid: 456, now: 103))
        XCTAssertTrue(sequence.accepts(changeCount: 12, pid: 456, now: 103))
    }
}
