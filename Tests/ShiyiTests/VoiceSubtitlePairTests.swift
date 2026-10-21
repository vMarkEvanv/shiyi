import XCTest
import AppKit
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
    func testKeepsTwoDistinctPairsAndRevisionsDoNotConsumeAnotherSlot() {
        var state = VoiceSubtitlePairState()
        let first = VoiceCaption(id: UUID(), original: "First", recordedAt: Date(timeIntervalSince1970: 1), translation: "第一句")
        var second = VoiceCaption(id: UUID(), original: "Second", recordedAt: Date(timeIntervalSince1970: 2), translation: "第二句")
        state.update([first]); state.update([second])
        XCTAssertEqual(state.visible.map(\.id), [first.id, second.id])
        second.translation = "第二句补全"
        state.update([second])
        XCTAssertEqual(state.visible.count, 2)
        XCTAssertEqual(state.visible.last?.translation, "第二句补全")
        let third = VoiceCaption(id: UUID(), original: "Third", recordedAt: Date(timeIntervalSince1970: 3), translation: "第三句")
        state.update([third])
        XCTAssertEqual(state.visible.map(\.id), [second.id, third.id])
        state.update([first])
        XCTAssertEqual(state.visible.map(\.id), [second.id, third.id])
        state.update([])
        XCTAssertTrue(state.visible.isEmpty)
    }
    @MainActor
    func testBlackContainerRemainsVisibleWhenEmptyAndHeightIsFixed() throws {
        let surface = NativeSubtitleSurface(frame: CGRect(x: 0, y: 0, width: 860, height: 200))
        let empty = surface.update(captions: [], fontSize: 17, width: 860, backgroundOpacity: 0.5)
        let background = try XCTUnwrap(surface.layer?.sublayers?.first)
        XCTAssertEqual(background.opacity, 1)
        XCTAssertEqual(background.backgroundColor?.alpha, 0.5)
        let caption = VoiceCaption(id: UUID(), original: "Hello", translation: "你好")
        let one = surface.update(captions: [caption], fontSize: 17, width: 860, backgroundOpacity: 0.5)
        let two = surface.update(captions: [caption, VoiceCaption(id: UUID(), original: "Next", translation: "下一句")], fontSize: 17, width: 860, backgroundOpacity: 0.5)
        XCTAssertEqual(empty, one); XCTAssertEqual(one, two)
        XCTAssertTrue(surface.layer?.masksToBounds == true)
        _ = surface.update(captions: [], fontSize: 17, width: 860, backgroundOpacity: 0.5)
        XCTAssertEqual(background.opacity, 1)
        surface.dismissUp()
        XCTAssertEqual(background.opacity, 0)
        surface.reveal()
        _ = surface.update(captions: [], fontSize: 17, width: 860, backgroundOpacity: 0.5)
        XCTAssertEqual(background.opacity, 1)
    }

}
