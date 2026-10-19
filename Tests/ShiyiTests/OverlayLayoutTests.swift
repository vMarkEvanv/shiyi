import XCTest
@testable import Shiyi

final class OverlayLayoutTests: XCTestCase {
    func testOperationPointDoesNotMoveWhenContentExpands() {
        let area = CGRect(x: -1920, y: 80, width: 1920, height: 1000)
        for x in [0.0, 0.5, 1.0] {
            for y in [0.0, 0.5, 1.0] {
                let compact = OverlayLayout.make(in: area, expanded: false, horizontal: x, vertical: y)
                let expanded = OverlayLayout.make(in: area, expanded: true, horizontal: x, vertical: y)
                XCTAssertEqual(compact.controlFrame, expanded.controlFrame)
                XCTAssertEqual(compact.contentFrame.maxY, expanded.contentFrame.maxY)
                XCTAssertEqual(compact.contentFrame.minX, expanded.contentFrame.minX)
                XCTAssertTrue(area.contains(compact.contentFrame))
                XCTAssertTrue(area.contains(expanded.contentFrame))
                XCTAssertTrue(compact.contentFrame.contains(compact.controlFrame))
                XCTAssertTrue(expanded.contentFrame.contains(expanded.controlFrame))
            }
        }
    }

    func testDisconnectedOrSmallerScreenCanUseClampedLayout() {
        let area = CGRect(x: 300, y: -600, width: 320, height: 280)
        let layout = OverlayLayout.make(in: area, expanded: true, horizontal: 5, vertical: -9)
        XCTAssertTrue(area.contains(layout.contentFrame))
        XCTAssertTrue(layout.contentFrame.contains(layout.controlFrame))
        XCTAssertLessThan(layout.contentFrame.width, OverlayLayout.width)
    }

    func testInvalidStoredValuesCannotMakeOverlayInvisibleOrOffscreen() {
        let area = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let layout = OverlayLayout.make(in: area, expanded: true, horizontal: .nan, vertical: .infinity)
        XCTAssertTrue(area.contains(layout.contentFrame))
        XCTAssertEqual(OverlayLayout.opacity(-10), 0.2)
        XCTAssertEqual(OverlayLayout.opacity(5), 1)
        XCTAssertEqual(OverlayLayout.opacity(.nan), 0.85)
    }

    func testLongTextBlocksPreserveAllUnicodeAndHaveNoEmptyTail() {
        let text = String(repeating: "👨‍👩‍👧‍👦原文 e\u{301}\n", count: 90)
        let blocks = OverlayText.blocks(text)
        XCTAssertEqual(blocks.joined(), text)
        XCTAssertGreaterThan(blocks.count, 1)
        XCTAssertTrue(blocks.allSatisfy { !$0.isEmpty && $0.count <= 180 })
        XCTAssertFalse(blocks.joined().contains("�"))
    }
}
