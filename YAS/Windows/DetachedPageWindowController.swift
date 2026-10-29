import AppKit

/// A page opened in its own window ("Open in New Window"). It is a separate page
/// instance reading the same Store, so it stays live alongside the pane's copy; it
/// shows all apps and is not driven by the list selection.
@MainActor
final class DetachedPageWindowController: NSWindowController, NSWindowDelegate {
    let kind: DetailPageKind
    let page: DetailPage
    private let onClose: (DetailPageKind) -> Void

    init(page: DetailPage, onClose: @escaping (DetailPageKind) -> Void) {
        kind = page.pageKind
        self.page = page
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = kind.title
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)

        let container = NSViewController()
        container.view = NSView()
        container.addChild(page)
        page.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            page.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            page.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        // Page controls (the map's pause/style buttons) float top-right, as in the pane.
        if let accessory = page.toolbarAccessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            container.view.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.topAnchor.constraint(equalTo: container.view.topAnchor, constant: 12),
                accessory.trailingAnchor.constraint(equalTo: container.view.trailingAnchor, constant: -10),
            ])
        }
        window.contentViewController = container
        window.setContentSize(NSSize(width: 820, height: 600))
        window.delegate = self
        let autosaveName = "DetachedPage-\(kind.rawValue)"
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        onClose(kind)
    }
}
