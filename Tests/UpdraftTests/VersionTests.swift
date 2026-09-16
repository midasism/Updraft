import XCTest
@testable import UpdraftKit

final class VersionTests: XCTestCase {
    func testDottedNumbersCompare() {
        XCTAssertLessThan(Version("1.3.5"), Version("1.4.4"))
        XCTAssertLessThan(Version("1.9.0"), Version("1.10.0"))
        XCTAssertLessThan(Version("0.9.15"), Version("0.23.0"))
    }

    func testLeadingVAndTrailingZerosAreIgnored() {
        XCTAssertEqual(Version("v1.2.3"), Version("1.2.3"))
        XCTAssertEqual(Version("1.0"), Version("1.0.0"))
        XCTAssertFalse(Version("1.0.0") > Version("1.0"))
    }

    func testSuffixMarksPrerelease() {
        XCTAssertLessThan(Version("2.1.0-beta.2"), Version("2.1.0"))
        XCTAssertLessThan(Version("2.1.0-beta.1"), Version("2.1.0-beta.2"))
        XCTAssertGreaterThan(Version("2.1.0"), Version("2.1.0-rc1"))
    }

    func testBrewRevisionSuffix() {
        XCTAssertLessThan(Version("3.39.8"), Version("3.39.11"))
        XCTAssertEqual(Version("3.39.11,dy27whJwwmb,a"), Version("3.39.11"))
    }

    func testNonNumericSegmentsFallBackToZero() {
        XCTAssertEqual(Version("abc"), Version("0"))
        XCTAssertLessThan(Version("1.x.0"), Version("1.1.0"))
    }

    // MARK: - 比对策略

    func testBuildNumberWinsOverShortVersion() {
        // Sparkle 里 build 号是权威的，shortVersion 可能没变。
        let newer = VersionComparison.isNewer(
            latest: .init(shortVersion: "1.4.4", buildVersion: "168"),
            than: .init(shortVersion: "1.4.4", buildVersion: "166")
        )
        XCTAssertTrue(newer)
    }

    func testFallsBackToShortVersionWhenBuildIsNotInteger() {
        let newer = VersionComparison.isNewer(
            latest: .init(shortVersion: "1.4.4", buildVersion: "beta-x"),
            than: .init(shortVersion: "1.3.5", buildVersion: "beta-w")
        )
        XCTAssertTrue(newer)
    }

    func testReturnsFalseWhenNothingIsComparable() {
        let newer = VersionComparison.isNewer(
            latest: .init(shortVersion: nil, buildVersion: nil),
            than: .init(shortVersion: nil, buildVersion: nil)
        )
        XCTAssertFalse(newer)
    }

    func testSameVersionIsNotAnUpdate() {
        let newer = VersionComparison.isNewer(
            latest: .init(shortVersion: "1.4.4", buildVersion: "168"),
            than: .init(shortVersion: "1.4.4", buildVersion: "168")
        )
        XCTAssertFalse(newer)
    }
}
