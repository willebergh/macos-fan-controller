import AppKit
import XCTest
@testable import FanControl

final class MenuErrorViewTests: XCTestCase {
    @MainActor
    func testErrorTextCannotWidenMenuOrGrowWithoutBound() {
        _ = NSApplication.shared
        let errors = [
            "Helper unavailable.",
            String(repeating: "W", count: 2000),
            String(repeating: "A long helper error with details. ", count: 200),
            String(repeating: "温度センサーエラー\n", count: 100)
        ]
        for error in errors {
            let view = MenuErrorView(error: error)
            XCTAssertEqual(view.frame.width, 290)
            let label = view.subviews.first as! NSTextField
            XCTAssertEqual(label.frame.width, 250)
            XCTAssertEqual(label.maximumNumberOfLines, 4)
            XCTAssertTrue(label.cell!.truncatesLastVisibleLine)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: label.font!)
            XCTAssertLessThanOrEqual(view.frame.height, ceil(lineHeight * 4) + 12)
            XCTAssertEqual(label.stringValue, "Error: \(error)")
            XCTAssertEqual(label.toolTip, error)
            XCTAssertEqual(view.toolTip, error)
        }
    }
}
