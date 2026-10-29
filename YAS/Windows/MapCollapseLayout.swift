import Foundation

/// Pure frame math for hiding/showing the map pane (tested).
enum MapCollapseLayout {
    enum Plan: Equatable {
        /// Resize the window to this frame (the list keeps its width).
        case resizeWindow(NSRect)
        /// Leave the window alone; collapse/uncollapse the pane inside it.
        case paneOnly
    }

    /// Hiding: shrink the window to the list's width, left edge fixed.
    /// Full screen can't shrink, so the list fills the window instead.
    static func collapse(windowFrame: NSRect, listWidth: CGFloat, isFullScreen: Bool) -> Plan {
        guard !isFullScreen, listWidth > 0, listWidth < windowFrame.width else { return .paneOnly }
        return .resizeWindow(NSRect(x: windowFrame.minX, y: windowFrame.minY, width: listWidth, height: windowFrame.height))
    }

    /// Showing: grow the window by `mapWidth`, left edge fixed. If that would leave
    /// the screen, split the current window when it's already wide enough for both
    /// panes (`minimumExpandedWidth`); otherwise shift left / clamp to fit on screen.
    static func expand(
        windowFrame: NSRect, mapWidth: CGFloat, visibleFrame: NSRect?, isFullScreen: Bool, minimumExpandedWidth: CGFloat
    ) -> Plan {
        guard !isFullScreen, mapWidth > 0 else { return .paneOnly }
        var target = NSRect(x: windowFrame.minX, y: windowFrame.minY,
                            width: windowFrame.width + mapWidth, height: windowFrame.height)
        guard let visible = visibleFrame else { return .resizeWindow(target) }
        if target.maxX <= visible.maxX { return .resizeWindow(target) }
        if windowFrame.width >= minimumExpandedWidth { return .paneOnly }
        target.size.width = min(max(minimumExpandedWidth, target.width), visible.width)
        target.origin.x = max(visible.minX, visible.maxX - target.width)
        return .resizeWindow(target)
    }
}
