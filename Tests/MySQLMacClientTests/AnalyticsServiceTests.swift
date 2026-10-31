import XCTest
@testable import MySQLMacClient

final class AnalyticsServiceTests: XCTestCase {
    /// Every backup, export or import a test runs would otherwise be sent
    /// to the analytics server as real usage.
    @MainActor
    func testSendsNothingFromATestRun() {
        XCTAssertTrue(AnalyticsService.isRunningTests)
    }
}
