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

        // 4b. A photo and a video stored the way the camera stores them (sideways, turned upright by
        // their orientation): the list's thumbnail, the first frame and the full picture must agree.
        step("open-camera-photo", settle: 3) { openFromFolder("row-e_camera.jpg") }
        step("close-swipe-down-camera-photo", settle: 2.5) { app.swipeDown() }
        step("open-camera-video", settle: 4) { openFromFolder("row-f_camera.mov") }
        step("close-swipe-down-camera-video", settle: 2.5) { app.swipeDown() }

        // 4c. Long folders of landscape files, so the folder shows above and below the picture while
        // the viewer fades: the row half under the tab bar (the folder must not scroll to it while
        // it can be seen), and paging past the bottom of the list (it may scroll only behind the
        // viewer, and stays put while a page is swiped away).
        goBack(expecting: "row-UITestLongImages")
        openFolder("row-UITestLongImages", first: "row-img_01.png")
        step("long-open-image-edge", settle: 3) { tapRowUnderTabBar(prefix: "row-img_") }
        closeWithButton("long-close-button-image-edge")
        step("long-open-image-edge-2", settle: 3) { tapRowUnderTabBar(prefix: "row-img_") }
        step("long-close-swipe-down-image-edge", settle: 2.5) { app.swipeDown() }
        step("long-open-image-top", settle: 3) { openFromFolder("row-img_05.png") }
        for index in 1...12 {
            step("page-long-\(index)", settle: 1.3) { app.swipeLeft() }
        }
        step("long-close-swipe-down-paged", settle: 2.5) { app.swipeDown() }
        goBack(expecting: "row-UITestLongVideos")
        openFolder("row-UITestLongVideos", first: "row-vid_01.mp4")
        step("long-open-video-edge", settle: 4) { tapRowUnderTabBar(prefix: "row-vid_") }
        step("long-close-swipe-down-video-edge", settle: 2.5) { app.swipeDown() }
        step("long-open-video-edge-2", settle: 4) { tapRowUnderTabBar(prefix: "row-vid_") }
        step("chrome-show-long-video", settle: 1.5) { tapViewer() }
        step("pause-long-video", settle: 1.5) { doubleTapVideoMiddle() }
        closeWithButton("long-close-button-video-edge")

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

        // 7. Held sideways: the folder turns with the phone, and a picture and a video open and close
        // sideways (the recording stays upright, so the probe log checks these).
        XCUIDevice.shared.orientation = .landscapeLeft
        mark("device-landscape")
        pause(3)
        step("sideways-open-image", settle: 3) { openFromFolder("cell-b_landscape.png") }
        step("sideways-chrome-show", settle: 1.5) { tapViewer() }
        closeWithButton("sideways-close-button-image")
        step("sideways-open-video", settle: 4) { openFromFolder("cell-d_landscape.mp4") }
        step("sideways-close-swipe-down-video", settle: 2.5) { app.swipeDown() }
        XCUIDevice.shared.orientation = .portrait
        mark("device-portrait")
        pause(3)
        mark("done")
    }

    /// The experiment of the repro workflow (tools/viewer_jump/config.env): each way of hosting the
    /// pager (`-ViewerEdgeVariant`, Debug builds only) opened upright and held sideways, paged, and
    /// turned with 横屏 / 竖屏.
    @MainActor
    func testEdgeVariants() throws {
        continueAfterFailure = true
        for variant in [0, 1, 2, 3] {
            launch(layout: "list", extra: ["-ViewerEdgeVariant", "\(variant)"])
            let folder = element("row-UITest")
            guard folder.waitForExistence(timeout: 120) else {
                XCTFail("the seeded folder shows up")
                continue
            }
            folder.tap()
            XCTAssertTrue(element("row-c_portrait.mp4").waitForExistence(timeout: 30))
            pause(2)
            let v = "v\(variant)"
            step(v + "-open-image-portrait", settle: 2.5) { openFromFolder("row-a_portrait.png") }
            step(v + "-close-swipe-down-portrait", settle: 2) { app.swipeDown() }
            XCUIDevice.shared.orientation = .landscapeLeft
            mark(v + "-device-landscape")
            pause(2.5)
            step(v + "-sideways-open-video", settle: 3) { openFromFolder("row-c_portrait.mp4") }
            step(v + "-sideways-chrome-show", settle: 1.5) { tapViewer() }
            step(v + "-sideways-close-swipe-down-video", settle: 2) { app.swipeDown() }
            step(v + "-sideways-open-image", settle: 3) { openFromFolder("row-b_landscape.png") }
            step(v + "-sideways-page", settle: 2) { app.swipeLeft() }
            step(v + "-sideways-close-swipe-down-paged", settle: 2) { app.swipeDown() }
            XCUIDevice.shared.orientation = .portrait
            mark(v + "-device-portrait")
            pause(2.5)
            step(v + "-open-video-landscape", settle: 3) { openFromFolder("row-d_landscape.mp4") }
            step(v + "-pause", settle: 1.5) { doubleTapVideoMiddle() }
            step(v + "-landscape-button", settle: 3) { tapIfPossible(app.buttons["横屏"]) }
            step(v + "-portrait-button", settle: 3) { tapIfPossible(app.buttons["竖屏"]) }
            closeWithButton(v + "-close-button")
            app.terminate()
        }
        mark("done")
    }

    // MARK: - Steps

    @MainActor
    private func launch(layout: String, extra: [String] = []) {
        app = XCUIApplication()
        // One video loops instead of the next file starting when it ends, so the test decides what
        // is on screen.
        app.launchArguments += [
            "-FileBoxUITestSeed", "-sortOrder", "name", "-folderLayoutV2", layout, "-mediaPlaybackMode", "repeatOne",
        ] + extra
        mark("launch-\(layout)")
        app.launch()
        mark("launched-\(layout)")
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Back to the folder above, by its back button (or the edge swipe if that is not there).
    @MainActor
    private func goBack(expecting identifier: String) {
        mark("go-back")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3), back.isHittable {
            back.tap()
        } else {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 10), "back in the folder above")
        pause(1.5)
    }

    @MainActor
    private func openFolder(_ identifier: String, first: String) {
        mark("open-folder-" + identifier)
        tapIfPossible(element(identifier))
        XCTAssertTrue(element(first).waitForExistence(timeout: 30), "the long folder shows")
        // Thumbnails load.
        pause(3)
    }

    /// Opens the file whose row the tab bar half covers: the first row that starts above the tab
    /// bar's top and ends below it (else the lowest row that starts above it). Tapped in its
    /// uncovered part.
    @MainActor
    private func tapRowUnderTabBar(prefix: String) {
        let screen = app.windows.firstMatch.frame
        let bar = app.tabBars.firstMatch
        let barTop = bar.exists && bar.frame.height > 0 ? bar.frame.minY : screen.maxY - 83
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
            .map { ($0, $0.frame) }
            .filter { $0.1.height > 10 && $0.1.maxY > 0 }
            .sorted { $0.1.minY < $1.1.minY }
        let target = rows.first { $0.1.minY < barTop - 16 && $0.1.maxY > barTop + 2 }
            ?? rows.last { $0.1.minY < barTop - 16 }
        guard let target else {
            mark("no-row-under-tab-bar")
            return
        }
        let (row, frame) = target
        mark(String(format: "row=%@/y=%.1f-%.1f/barTop=%.1f", row.identifier, frame.minY, frame.maxY, barTop))
        let y = (frame.minY + min(frame.maxY, barTop)) / 2
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: y)).tap()
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
        if !(close.waitForExistence(timeout: 3) && close.isHittable) {
            // The bars are hidden: show them first.
            mark("show-bars-for-close")
            tapViewer()
            pause(0.6)
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
