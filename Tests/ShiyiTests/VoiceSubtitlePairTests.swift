import XCTest
@testable import Shiyi

final class VoiceSubtitlePairTests: XCTestCase {
    func testPendingOriginalDoesNotAppearBeforeItsTranslationOrReplacePreviousPair() {
        var state = VoiceSubtitlePairState()
        let first = VoiceCaption(id: UUID(), original: "First", recordedAt: Date(timeIntervalSince1970: 1))
        state.update([first])
        XCTAssertNil(state.caption)
        var complete = first; complete.translation = "第一句"
        state.update([complete])
        XCTAssertEqual(state.caption?.original, "First")
        let next = VoiceCaption(id: UUID(), original: "Next", recordedAt: Date(timeIntervalSince1970: 2))
        state.update([complete, next])
        XCTAssertEqual(state.caption, complete)
        var ready = next; ready.translation = "下一句"
        state.update([complete, ready])
        XCTAssertEqual(state.caption, ready)
    }
    func testRevisionDoesNotJumpBackToAnOlderPairAndClearRemovesText() {
        var state = VoiceSubtitlePairState()
        let first = VoiceCaption(id: UUID(), original: "First", recordedAt: Date(timeIntervalSince1970: 1), translation: "一")
        var second = VoiceCaption(id: UUID(), original: "Second", recordedAt: Date(timeIntervalSince1970: 2), translation: "二")
        state.update([first, second])
        second.original = "Revised second"; second.translation = ""
        state.update([first, second])
        XCTAssertEqual(state.caption?.original, "Second")
        second.translation = "修订的第二句"
        state.update([first, second])
        XCTAssertEqual(state.caption?.original, "Revised second")
        state.update([])
        XCTAssertNil(state.caption)
    }
}
