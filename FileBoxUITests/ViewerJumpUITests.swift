import XCTest

/// Drives the media viewer the way the user does, for the repro workflow that records the
/// simulator's screen (see .github/workflows/repro.yml and tools/viewer_jump). Every step prints
/// "UITEST-EVENT <unix time> <name>" before and after it, so the recording's frames can be matched
/// to the steps. The app seeds the test folder itself (`-FileBoxUITestSeed`, Debug builds only).
final class ViewerJumpUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    func testViewerOpenPageToggleClose() throws {
        continueAfterFailure = true
        launch(layout: "list")
        let folder = element("row-UITest")
        XCTAssertTrue(folder.waitForExistence(timeout: 120), "the seeded folder shows up")
        mark("tap-folder")
        folder.tap()
        let portrait = element("row-a_portrait.png")
        XCTAssertTrue(portrait.waitForExistence(timeout: 30), "the seeded files show up")
        XCTAssertTrue(element("row-d_landscape.mp4").waitForExistence(timeout: 30))
        // Thumbnails and durations load.
        pause(3)

        // 1. First image open after launch; the bars on and off; close with the button.
        step("open-image-portrait-1", settle: 3) { portrait.tap() }
        step("chrome-show-1", settle: 2) { tapViewer() }
        step("chrome-hide-1", settle: 2) { tapViewer() }
        step("chrome-show-2", settle: 1.5) { tapViewer() }
        closeWithButton("close-button-1")

        // 2. Open again, then page through image, image, video, video and back.
        step("open-image-portrait-2", settle: 3) { portrait.tap() }
        step("page-to-landscape-image", settle: 2.5) { app.swipeLeft() }
        step("page-to-portrait-video", settle: 3.5) { app.swipeLeft() }
        step("page-to-landscape-video", settle: 3.5) { app.swipeLeft() }
        step("page-back-to-portrait-video", settle: 3.5) { app.swipeRight() }
        step("chrome-show-video", settle: 2) { tapViewer() }
        step("chrome-hide-video", settle: 2) { tapViewer() }
        step("close-swipe-down-1", settle: 2.5) { app.swipeDown() }

        // 3. Videos opened straight from the list. A playing video's bars hide by themselves after
        // 3 s, so it is paused (double tap in the middle) before the close button is used.
        step("open-video-portrait", settle: 4) { openFromFolder("row-c_portrait.mp4") }
        step("chrome-show-video-2", settle: 1.5) { tapViewer() }
        step("pause-video", settle: 1.5) { doubleTapVideoMiddle() }
        closeWithButton("close-button-video")
        step("open-video-landscape", settle: 4) { openFromFolder("row-d_landscape.mp4") }
        step("close-swipe-down-2", settle: 2.5) { app.swipeDown() }

        // 4. The landscape image straight from the list.
        step("open-image-landscape", settle: 3) { openFromFolder("row-b_landscape.png") }
        step("close-swipe-down-3", settle: 2.5) { app.swipeDown() }

        // 5. A fresh launch with the grid: the first open of each kind again.
        app.terminate()
        launch(layout: "grid")
        let gridFolder = element("cell-UITest")
        if !gridFolder.waitForExistence(timeout: 60) {
            XCTFail("the seeded folder shows up in the grid")
            return
        }
        mark("tap-folder-grid")
        gridFolder.tap()
        let gridImage = element("cell-a_portrait.png")
        XCTAssertTrue(gridImage.waitForExistence(timeout: 30))
        pause(3)
        step("grid-open-image-portrait", settle: 3) { gridImage.tap() }
        step("grid-chrome-show", settle: 1.5) { tapViewer() }
        closeWithButton("grid-close-button")
        step("grid-open-video-portrait", settle: 4) { openFromFolder("cell-c_portrait.mp4") }
        step("grid-close-swipe-down", settle: 2.5) { app.swipeDown() }

        // 6. A landscape video turned sideways with 横屏 and back with 竖屏 (checked by the probe log;
        // the recording stays upright). Reached through the portrait video: on the smallest phone the
        // grid's last cell sits under the bar. Paused first, so the bars stay up and the buttons are
        // really there when tapped (a video paused by a double tap brings its bars up by itself).
        // Nothing here fails the test; a missing button is only marked.
        step("grid-open-video-portrait-2", settle: 3) { openFromFolder("cell-c_portrait.mp4") }
        step("page-to-landscape-video-2", settle: 3.5) { app.swipeLeft() }
        step("pause-before-rotation", settle: 2) { doubleTapVideoMiddle() }
        step("landscape-button", settle: 3) { tapIfPossible(app.buttons["横屏"]) }
        step("portrait-button", settle: 3) { tapIfPossible(app.buttons["竖屏"]) }
        closeWithButton("close-button-after-rotation")
        mark("done")
    }

    // MARK: - Steps

    @MainActor
    private func launch(layout: String) {
        app = XCUIApplication()
        // One video loops instead of the next file starting when it ends, so the test decides what
        // is on screen.
        app.launchArguments += [
            "-FileBoxUITestSeed", "-sortOrder", "name", "-folderLayoutV2", layout, "-mediaPlaybackMode", "repeatOne",
        ]
        mark("launch-\(layout)")
        app.launch()
        mark("launched-\(layout)")
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A single tap on the page, away from the video's centre buttons.
    @MainActor
    private func tapViewer() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    }

    /// Opens a file from the folder. If a viewer is still open over it (a close that did not take),
    /// it is swiped away first.
    @MainActor
    private func openFromFolder(_ identifier: String) {
        let target = element(identifier)
        if !(target.waitForExistence(timeout: 5) && target.isHittable) {
            mark("viewer-still-open")
            app.swipeDown()
            pause(2.5)
        }
        tapIfPossible(target)
    }

    /// Plays or pauses a video: a double tap in the middle third, below the centre buttons.
    @MainActor
    private func doubleTapVideoMiddle() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64)).doubleTap()
    }

    @MainActor
    private func tapIfPossible(_ target: XCUIElement) {
        if target.waitForExistence(timeout: 3), target.isHittable {
            target.tap()
        } else {
            mark("skipped-tap")
        }
    }

    @MainActor
    private func closeWithButton(_ name: String) {
        let close = element("viewer-close")
        if !close.waitForExistence(timeout: 3) {
            // The bars were hidden after all: show them first.
            tapViewer()
            _ = close.waitForExistence(timeout: 3)
        }
        step(name, settle: 2.5) { tapIfPossible(close) }
    }

    @MainActor
    private func step(_ name: String, settle: TimeInterval, _ action: () -> Void) {
        mark(name + ".begin")
        action()
        mark(name)
        pause(settle)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func mark(_ name: String) {
        print(String(format: "UITEST-EVENT %.3f %@", Date().timeIntervalSince1970, name))
    }
}
