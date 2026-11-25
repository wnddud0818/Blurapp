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

    /// Opens the full-screen area editor and returns the photo in it.
    private func openAreaEditor() -> XCUIElement {
        app.buttons["직접 추가"].tap()
        let photo = app.images["region-photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        return photo
    }

    /// Drags between two points given as fractions of `element`.
    private func drag(_ element: XCUIElement, from start: CGVector, to end: CGVector) {
        element.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.2, thenDragTo: element.coordinate(withNormalizedOffset: end))
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
        let cell = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 90), app.debugDescription)
        cell.tap()
        let submit = app.navigationBars.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "(Add|Done|추가|완료)(.*)")).firstMatch
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
        let photo = openAreaEditor()
        drag(photo, from: CGVector(dx: 0.35, dy: 0.35), to: CGVector(dx: 0.58, dy: 0.59))
        app.buttons["완료"].tap()
        XCTAssertTrue(app.staticTexts["남긴 대상 1개"].waitForExistence(timeout: 10))
        app.buttons["골라서 가리기"].tap()
        app.buttons["골라서 남기기"].tap()
        XCTAssertTrue(app.staticTexts["남긴 대상 1개"].exists)
        app.buttons["photos-menu"].tap()
        app.buttons["모두 닫기"].tap()
        app.buttons["모두 닫기"].tap()
        XCTAssertTrue(app.buttons["사진 선택하기"].waitForExistence(timeout: 5))
    }

    func testFullScreenAreasStayUntilDoneAndDeleteFromTheList() throws {
        openSample()
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "가린 영역")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let before = try XCTUnwrap(Int(status.label.filter(\.isNumber)))

        // Two areas in the empty sky, one after the other. A new area is selected right away.
        let photo = openAreaEditor()
        let count = app.staticTexts["region-count"]
        let opened = try XCTUnwrap(Int(count.label.filter(\.isNumber)))
        XCTAssertFalse(app.buttons["삭제"].exists, "nothing is selected yet")
        drag(photo, from: CGVector(dx: 0.46, dy: 0.04), to: CGVector(dx: 0.6, dy: 0.2))
        drag(photo, from: CGVector(dx: 0.76, dy: 0.04), to: CGVector(dx: 0.92, dy: 0.2))
        XCTAssertEqual(count.label, "영역 \(opened + 2)개")
        app.buttons["삭제"].tap()
        XCTAssertEqual(count.label, "영역 \(opened + 1)개")
        app.buttons["완료"].tap()
        XCTAssertTrue(app.staticTexts["가린 영역 \(before + 1)개"].waitForExistence(timeout: 10))

        // Long-press the new area in the list and delete it.
        let drawn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "수동")).allElementsBoundByIndex.last
        try XCTUnwrap(drawn).press(forDuration: 1.1)
        app.buttons["삭제"].tap()
        XCTAssertTrue(app.staticTexts["가린 영역 \(before)개"].waitForExistence(timeout: 10))
    }
}
