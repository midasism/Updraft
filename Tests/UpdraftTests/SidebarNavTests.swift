import XCTest
@testable import UpdraftKit

/// 侧栏 ↑↓ 的落点。视图只负责把方向键换算成 ±1，边界在这里被钉死：
/// 首项再往上、末项再往下都必须原地不动，不能绕回另一端。
final class SidebarNavTests: XCTestCase {
    func testAdvancedMovesOneStepInOrder() {
        XCTAssertEqual(SidebarNav.all.advanced(by: 1), .updateAvailable)
        XCTAssertEqual(SidebarNav.updateAvailable.advanced(by: 1), .upToDate)
        XCTAssertEqual(SidebarNav.upToDate.advanced(by: 1), .unsupported)
        XCTAssertEqual(SidebarNav.unsupported.advanced(by: -1), .upToDate)
    }

    func testAdvancedClampsAtBothEnds() {
        XCTAssertEqual(SidebarNav.all.advanced(by: -1), .all)
        XCTAssertEqual(SidebarNav.all.advanced(by: -99), .all)
        XCTAssertEqual(SidebarNav.unsupported.advanced(by: 1), .unsupported)
        XCTAssertEqual(SidebarNav.unsupported.advanced(by: 99), .unsupported)
    }
}
