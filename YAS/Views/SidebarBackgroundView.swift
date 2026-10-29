import AppKit

/// Left pane background: behind-window vibrancy under a dark gradient that warms
/// towards the bottom, like the reference design.
final class SidebarBackgroundView: NSView {
    private let effectView = NSVisualEffectView()
    private let gradientLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .followsWindowActiveState
        effectView.autoresizingMask = [.width, .height]
        effectView.frame = bounds
        addSubview(effectView)

        let gradientHost = NSView(frame: bounds)
        gradientHost.autoresizingMask = [.width, .height]
        gradientHost.wantsLayer = true
        gradientLayer.colors = [Theme.listLeftTop.cgColor, Theme.listLeftMiddle.cgColor, Theme.listLeftBottom.cgColor]
        gradientLayer.locations = [0, 0.55, 1]
        // Layer coordinates are flipped relative to the view: (0,1) is the top.
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientHost.layer = gradientLayer
        addSubview(gradientHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
