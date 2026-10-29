import SwiftUI
import XCTest
@testable import RecordMac

@MainActor
final class CapabilityBannerModelTests: XCTestCase {
    private func model(_ reductions: [String] = []) -> CapabilityBannerModel {
        CapabilityBannerModel(detect: { reductions })
    }

    func testNoReductionsShowsNothing() {
        let banner = model()
        banner.publish([])
        XCTAssertEqual(banner.visibleReductions, [])
    }

    func testEveryReductionIsShownInOrder() {
        let banner = model()
        banner.publish(["a", "b"])
        XCTAssertEqual(banner.visibleReductions, ["a", "b"])
    }

    func testAResolvedReductionDisappears() {
        let banner = model()
        banner.publish(["a", "b"])
        banner.publish(["b"])
        XCTAssertEqual(banner.visibleReductions, ["b"])
    }

    func testDismissingHidesTheReportAndTheSameReportShowsAgain() {
        let banner = model()
        banner.publish(["a"])
        banner.dismiss()
        XCTAssertEqual(banner.visibleReductions, [])
        banner.publish(["a"])
        XCTAssertEqual(banner.visibleReductions, ["a"])
    }

    func testANewReductionAfterDismissIsShown() {
        let banner = model()
        banner.publish(["a"])
        banner.dismiss()
        banner.publish(["a", "new"])
        XCTAssertEqual(banner.visibleReductions, ["a", "new"])
    }

    func testAnEarlierRunCannotReplaceANewerReport() {
        let banner = model()
        banner.refresh()
        banner.refresh()
        banner.publish(["stale"], from: 1)
        XCTAssertEqual(banner.visibleReductions, [])
        banner.publish(["latest"], from: 2)
        XCTAssertEqual(banner.visibleReductions, ["latest"])
    }

    func testLaunchDetectionRunsOnceAndPublishes() async {
        let runs = RunCounter()
        let banner = CapabilityBannerModel(detect: {
            runs.increment()
            return ["reduced"]
        })
        banner.detectAtLaunch()
        banner.detectAtLaunch()
        for _ in 0..<200 where banner.visibleReductions.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(banner.visibleReductions, ["reduced"])
        XCTAssertEqual(runs.value, 1)
    }

    // MARK: Layout

    private func fittingHeight(_ reductions: [String], insets: EdgeInsets = EdgeInsets()) -> CGFloat {
        let banner = model()
        banner.publish(reductions)
        let host = NSHostingView(rootView: CapabilityBanner(model: banner, insets: insets).frame(width: 628))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testAnEmptyBannerTakesNoSpaceWithItsInsets() {
        XCTAssertEqual(fittingHeight([], insets: EdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16)), 0)
    }

    func testOneReductionTakesOneRowAndManyStayWithinTheBound() {
        let one = fittingHeight(["Presenter Overlay is reduced: the system composite cannot be kept out of the clean screen stream"])
        XCTAssertGreaterThan(one, 0)
        XCTAssertLessThan(one, 60)
        let many = fittingHeight(Array(repeating: String(repeating: "a long reduction message ", count: 8), count: 12))
        XCTAssertLessThanOrEqual(many, 96 + 2 * Theme.space3 + 1)
        print("capability banner heights: one \(one), twelve long \(many)")
    }

    func testLaunchDetectionOnThisMachineReportsThePresenterOverlayFallback() async {
        let banner = CapabilityBannerModel()
        banner.detectAtLaunch()
        for _ in 0..<400 where banner.visibleReductions.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(banner.visibleReductions.contains { $0.hasPrefix("Presenter Overlay is reduced") })
        print("capability banner at launch: \(banner.visibleReductions)")
    }
}

private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
