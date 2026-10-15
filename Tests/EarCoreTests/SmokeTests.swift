import XCTest

@testable import EarCore

final class SmokeTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(EarCore.version.isEmpty)
    }
}
