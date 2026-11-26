import XCTest
@testable import Porridge

/// The Add popover's height on an iPad (`AddSheet.popoverHeight`): the content's where it fits, else the room, from
/// the window alone. A height it gives never asks for another one, so the popover cannot swing between two sizes.
@MainActor
final class AddPopoverHeightTests: XCTestCase {
    /// 11-inch iPad: landscape 834 pt high, portrait 1210 pt; the home indicator's safe area 20 pt, the popover's top
    /// at y 32.
    private let landscapeRoom = AddSheet.popoverRoom(bottom: 834 - 20, top: 32)
    private let portraitRoom = AddSheet.popoverRoom(bottom: 1210 - 20, top: 32)

    func testRoomIsTheWindowLessTopAndMargin() {
        XCTAssertEqual(landscapeRoom, 770)
        XCTAssertEqual(portraitRoom, 1146)
        XCTAssertEqual(AddSheet.popoverRoom(bottom: 200, top: 32), AddSheet.minPopoverRoom)
    }

    func testContentThatFitsGetsItsHeight() {
        XCTAssertEqual(AddSheet.popoverHeight(content: 740, room: landscapeRoom), 740)
        XCTAssertEqual(AddSheet.popoverHeight(content: 1120, room: portraitRoom), 1120)
        XCTAssertEqual(AddSheet.popoverHeight(content: 739.2, room: landscapeRoom), 740)
    }

    func testHigherContentGetsTheWholeRoom() {
        XCTAssertEqual(AddSheet.popoverHeight(content: 1180, room: landscapeRoom), 770)
        XCTAssertEqual(AddSheet.popoverHeight(content: 5000, room: portraitRoom), 1146)
    }

    func testUnmeasuredContentGetsTheWholeRoom() {
        XCTAssertEqual(AddSheet.popoverHeight(content: 0, room: landscapeRoom), 770)
    }

    func testApplyingTwiceChangesNothing() {
        for room in [landscapeRoom, portraitRoom, AddSheet.minPopoverRoom] {
            for content in stride(from: CGFloat(0), through: 1600, by: 7.3) {
                let once = AddSheet.popoverHeight(content: content, room: room)
                XCTAssertEqual(AddSheet.popoverHeight(content: once, room: room), once, "content \(content), room \(room)")
                XCTAssertLessThanOrEqual(once, room)
            }
        }
    }

    /// The height grows with the measured content and never falls while it grows (the list's estimates only rise to
    /// the rows' real heights), so a series of measurements settles.
    func testHeightNeverFallsWhileTheContentGrows() {
        var last: CGFloat = 0
        for content in stride(from: CGFloat(1), through: 1600, by: 13) {
            let height = AddSheet.popoverHeight(content: content, room: landscapeRoom)
            XCTAssertGreaterThanOrEqual(height, last)
            last = height
        }
    }
}
