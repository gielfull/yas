import AppKit
import XCTest
@testable import YAS

final class MapCollapseLayoutTests: XCTestCase {
    private let window = NSRect(x: 100, y: 50, width: 1200, height: 820)
    private let screen = NSRect(x: 0, y: 0, width: 2560, height: 1400)

    func testCollapseKeepsLeftEdgeAndListWidth() {
        XCTAssertEqual(
            MapCollapseLayout.collapse(windowFrame: window, listWidth: 440, isFullScreen: false),
            .resizeWindow(NSRect(x: 100, y: 50, width: 440, height: 820)))
    }

    func testCollapseInFullScreenOnlyCollapsesThePane() {
        XCTAssertEqual(MapCollapseLayout.collapse(windowFrame: window, listWidth: 440, isFullScreen: true), .paneOnly)
        XCTAssertEqual(MapCollapseLayout.collapse(windowFrame: window, listWidth: 1200, isFullScreen: false), .paneOnly,
                       "nothing to remove if the list already fills the window")
    }

    func testExpandRestoresMapWidthAnchoredLeft() {
        let collapsed = NSRect(x: 100, y: 50, width: 440, height: 820)
        XCTAssertEqual(
            MapCollapseLayout.expand(windowFrame: collapsed, mapWidth: 760, visibleFrame: screen, isFullScreen: false,
                                     minimumExpandedWidth: 820),
            .resizeWindow(NSRect(x: 100, y: 50, width: 1200, height: 820)))
    }

    func testExpandThatWouldLeaveTheScreen() {
        // Wide enough already: split the window instead of resizing it.
        let wide = NSRect(x: 1400, y: 50, width: 1000, height: 820)
        XCTAssertEqual(
            MapCollapseLayout.expand(windowFrame: wide, mapWidth: 760, visibleFrame: screen, isFullScreen: false,
                                     minimumExpandedWidth: 820),
            .paneOnly)
        // Too narrow for both panes: shift left so the grown window fits.
        let narrow = NSRect(x: 2000, y: 50, width: 440, height: 820)
        XCTAssertEqual(
            MapCollapseLayout.expand(windowFrame: narrow, mapWidth: 760, visibleFrame: screen, isFullScreen: false,
                                     minimumExpandedWidth: 820),
            .resizeWindow(NSRect(x: 1360, y: 50, width: 1200, height: 820)))
        // Screen smaller than the requested width: clamp to the screen.
        let small = NSRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(
            MapCollapseLayout.expand(windowFrame: NSRect(x: 500, y: 0, width: 440, height: 700), mapWidth: 760,
                                     visibleFrame: small, isFullScreen: false, minimumExpandedWidth: 820),
            .resizeWindow(NSRect(x: 0, y: 0, width: 1000, height: 700)))
    }

    func testExpandInFullScreenOnlyUncollapsesThePane() {
        XCTAssertEqual(
            MapCollapseLayout.expand(windowFrame: window, mapWidth: 760, visibleFrame: screen, isFullScreen: true,
                                     minimumExpandedWidth: 820),
            .paneOnly)
    }

    func testMapVisibilityPreferencesPersist() {
        let keys = ["isMapHidden", "mapPaneWidth"]
        let saved = StoredDefaults(keys)
        defer { saved.restore() }

        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        Preferences.registerDefaults()
        XCTAssertFalse(Preferences.isDetailPaneHidden, "detail pane shown by default")
        XCTAssertEqual(Preferences.mapPaneWidth, 760)

        Preferences.isDetailPaneHidden = true
        Preferences.mapPaneWidth = 900
        XCTAssertEqual(UserDefaults.standard.object(forKey: "isMapHidden") as? Bool, true)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "mapPaneWidth"), 900)
        Preferences.mapPaneWidth = 10
        XCTAssertEqual(Preferences.mapPaneWidth, 360, "never restores a map narrower than its minimum")
    }
}
