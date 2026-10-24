import XCTest
@testable import Hearsay

final class MeetingCalendarHeatTests: XCTestCase {
    func testHeatLevelsStepUpLikeAContributionGraph() {
        XCTAssertEqual([0, 1, 2, 3, 4, 6, 7, 12].map(MeetingCalendarView.heatLevel(for:)), [0, 1, 2, 2, 3, 3, 4, 4])
    }
}
