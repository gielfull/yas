import XCTest
@testable import YAS

final class YASTests: XCTestCase {
    @MainActor
    func testAppDelegateInstantiates() {
        XCTAssertNotNil(AppDelegate())
    }
}
