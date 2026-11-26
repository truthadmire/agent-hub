import XCTest
import HubKit

final class PresentationTextTests: XCTestCase {
    func testStatusTitlesAndUnrecognizedCodes() {
        XCTAssertEqual(HubPresentation.attentionTitle("merge_conflict"), "请处理合并冲突")
        XCTAssertEqual(HubPresentation.attentionTitle("provider_specific"), "provider_specific")
        XCTAssertEqual(VerificationState.notRun.rawValue, "not_run")
        XCTAssertEqual(HubPresentation.verificationStateTitle(.notRun), "未运行")
    }

    func testVerificationLabelsPreserveCommandsAndHumanText() {
        XCTAssertEqual(HubPresentation.verificationTitle("Baseline · Python syntax"), "基线 · Python 语法检查")
        XCTAssertEqual(HubPresentation.verificationTitle("Check 2 · /tmp/My Tool"), "检查 2 · /tmp/My Tool")
        XCTAssertEqual(HubPresentation.verificationTitle("Human · Swift build"), "人工验收 · Swift build")
        XCTAssertEqual(HubPresentation.verificationTitle("Human · Check 2 · keep My Words"), "人工验收 · Check 2 · keep My Words")
        XCTAssertEqual(HubPresentation.verificationTitle("Check · custom"), "Check · custom")
        XCTAssertEqual(HubPresentation.verificationTitle("Custom Check"), "Custom Check")
    }
}
