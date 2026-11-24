import XCTest

final class WorkspaceTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    private func openSample() {
        let start = app.buttons["예시 사진으로 연습"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        if !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.buttons["tool-영역"].waitForExistence(timeout: 15))
    }

    func testEditPreviewRotateAndReturnToWork() {
        app.buttons["원본 보기"].tap()
        XCTAssertTrue(app.buttons["가림 보기"].exists)
        openSample()
        let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "가린 영역")).firstMatch.label
        app.buttons["tool-효과"].tap()
        for name in ["육각 모자이크", "크리스털", "블러", "검정 가림", "모자이크"] {
            let choice = app.buttons[name]
            if !choice.isHittable { app.scrollViews.containing(.button, identifier: "모자이크").firstMatch.swipeLeft() }
            choice.tap()
            XCTAssertTrue(choice.isSelected)
        }
        app.buttons["강하게"].tap()
        app.buttons["결과 보기"].tap()
        XCTAssertFalse(app.buttons["tool-효과"].exists)
        let before = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = before == .unknown ? .portrait : before }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["편집 보기"].waitForExistence(timeout: 8))
        app.buttons["편집 보기"].tap()
        XCTAssertTrue(app.buttons["강하게"].isSelected)
        XCTAssertTrue(app.staticTexts[count].exists)
        app.buttons["tool-저장"].tap()
        XCTAssertTrue(app.buttons["새 사진으로 저장"].isEnabled)
    }

    func testSaveThenPickCopyAndRemoveIt() throws {
        #if targetEnvironment(simulator)
        openSample()
        app.buttons["tool-저장"].tap()
        app.buttons["새 사진으로 저장"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "허용", "OK", "확인"])).firstMatch
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(app.buttons["사진 앱에 저장됨"].waitForExistence(timeout: 12))
        app.buttons["photos-menu"].tap()
        app.buttons["사진 추가"].tap()
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 12), app.debugDescription)
        cell.tap()
        let submit = app.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "(Add|Done|추가|완료)(.*)")).firstMatch
        XCTAssertTrue(submit.exists, app.debugDescription)
        submit.tap()
        let second = app.buttons["사진 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 12))
        app.buttons["사진 1"].tap()
        XCTAssertTrue(app.buttons["사진 1"].isSelected)
        second.press(forDuration: 1.1)
        app.buttons["목록에서 빼기"].tap()
        XCTAssertFalse(second.exists)
        #else
        throw XCTSkip("Simulator photo library only.")
        #endif
    }

    func testModesManualRegionAndClose() {
        openSample()
        app.buttons["골라서 남기기"].tap()
        app.buttons["직접 추가"].tap()
        let bounds = app.buttons["결과 보기"]
        XCTAssertFalse(bounds.exists)
        let canvas = app.descendants(matching: .any).matching(identifier: "canvas").firstMatch
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.59))
        from.press(forDuration: 0.2, thenDragTo: to)
        XCTAssertTrue(app.staticTexts["남긴 대상 1개"].waitForExistence(timeout: 10))
        app.buttons["골라서 가리기"].tap()
        app.buttons["골라서 남기기"].tap()
        XCTAssertTrue(app.staticTexts["남긴 대상 1개"].exists)
        app.buttons["photos-menu"].tap()
        app.buttons["모두 닫기"].tap()
        app.buttons["모두 닫기"].tap()
        XCTAssertTrue(app.buttons["사진 선택하기"].waitForExistence(timeout: 5))
    }
}
