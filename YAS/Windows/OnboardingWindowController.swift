import AppKit
import YASShared

/// First-run steps: move to /Applications, approve the system
/// extension, allow the content filter, pick a mode. Each step shows live status.
@MainActor
final class OnboardingWindowController: NSWindowController {
    private final class StepView: NSStackView {
        let statusIcon = NSImageView()
        let detailLabel = NSTextField(wrappingLabelWithString: "")
        let button = NSButton()

        init(number: Int, title: String) {
            super.init(frame: .zero)
            orientation = .horizontal
            alignment = .top
            spacing = 12

            statusIcon.translatesAutoresizingMaskIntoConstraints = false
            statusIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            statusIcon.heightAnchor.constraint(equalToConstant: 22).isActive = true

            let titleLabel = NSTextField(labelWithString: "\(number). \(title)")
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.preferredMaxLayoutWidth = 330
            let text = NSStackView(views: [titleLabel, detailLabel])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 3

            button.bezelStyle = .push
            button.setContentHuggingPriority(.required, for: .horizontal)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            for view in [statusIcon, text, spacer, button] { addArrangedSubview(view) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func setStatus(done: Bool, waiting: Bool = false, detail: String) {
            let symbol = done ? "checkmark.circle.fill" : (waiting ? "clock.fill" : "circle.dashed")
            statusIcon.image = Theme.symbol(symbol, pointSize: 17, weight: .medium)
            statusIcon.contentTintColor = done ? Theme.activeGreen : (waiting ? .systemOrange : .tertiaryLabelColor)
            detailLabel.stringValue = detail
        }
    }

    private let store: Store
    private let extensionManager: ExtensionManager
    private let moveStep = StepView(number: 1, title: String(localized: "Move to Applications"))
    private let extensionStep = StepView(number: 2, title: String(localized: "Allow the system extension"))
    private let filterStep = StepView(number: 3, title: String(localized: "Allow the content filter"))
    private let modeStep = StepView(number: 4, title: String(localized: "Choose how to filter"))
    private let modePopUp = NSPopUpButton()

    init(store: Store, extensionManager: ExtensionManager) {
        self.store = store
        self.extensionManager = extensionManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = String(localized: "Welcome to YAS")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContent()
        window.center()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: ExtensionManager.stateDidChange, object: extensionManager)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: Store.modeDidChange, object: store)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeContent() -> NSView {
        let heading = NSTextField(labelWithString: String(localized: "Set up YAS"))
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(labelWithString: String(localized: "Yet Another Shield"))
        subtitle.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        let intro = NSTextField(wrappingLabelWithString: String(localized: "YAS uses a network extension to see which apps connect where. macOS asks you to approve it twice.") + "\n\n"
            + String(localized: "Until then YAS runs in monitor-only mode: it shows your own apps' connections, but can't block anything, count bytes, or see system processes."))
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 500

        moveStep.button.title = String(localized: "Move…")
        moveStep.button.target = self
        moveStep.button.action = #selector(move(_:))
        extensionStep.button.target = self
        extensionStep.button.action = #selector(installOrOpenSettings(_:))
        filterStep.button.title = String(localized: "Enable Filter")
        filterStep.button.target = self
        filterStep.button.action = #selector(enableFilter(_:))

        for mode in FilterMode.menuOrder {
            modePopUp.addItem(withTitle: mode.title)
            modePopUp.lastItem?.representedObject = mode.rawValue
            modePopUp.lastItem?.toolTip = mode.summary
        }
        modePopUp.target = self
        modePopUp.action = #selector(modeChanged(_:))
        modeStep.button.isHidden = true
        modeStep.addArrangedSubview(modePopUp)

        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(finish(_:)))
        done.keyEquivalent = "\r"

        let stack = NSStackView(views: [heading, subtitle, intro, moveStep, extensionStep, filterStep, modeStep, done])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(2, after: heading)
        stack.setCustomSpacing(22, after: intro)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        for step in [moveStep, extensionStep, filterStep, modeStep] {
            step.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        }
        stack.setCustomSpacing(24, after: modeStep)
        done.leadingAnchor.constraint(greaterThanOrEqualTo: stack.leadingAnchor).isActive = true
        return stack
    }

    @objc private func refresh() {
        let inApplications = extensionManager.isRunningFromApplications
        moveStep.setStatus(
            done: inApplications,
            detail: inApplications
                ? String(localized: "YAS is in /Applications.")
                : String(localized: "macOS only activates extensions for apps in /Applications."))
        moveStep.button.isHidden = inApplications

        let state = extensionManager.state
        switch state {
        case .needsUserApproval:
            extensionStep.setStatus(done: false, waiting: true, detail: String(localized: "Open System Settings > General > Login Items & Extensions > Network Extensions and turn on YAS."))
            extensionStep.button.title = String(localized: "Open System Settings")
        case .activating:
            extensionStep.setStatus(done: false, waiting: true, detail: state.localizedDescription)
            extensionStep.button.title = String(localized: "Open System Settings")
        case .enabled, .disabled:
            extensionStep.setStatus(done: true, detail: String(localized: "The extension is installed."))
            extensionStep.button.title = String(localized: "Open System Settings")
        case .error(let message):
            extensionStep.setStatus(done: false, detail: message)
            extensionStep.button.title = String(localized: "Try Again")
        case .notInstalled, .unknown:
            extensionStep.setStatus(done: false, detail: String(localized: "Installs the network filter. macOS will ask for your approval."))
            extensionStep.button.title = String(localized: "Install Extension")
        }
        extensionStep.button.isEnabled = inApplications || state == .needsUserApproval

        let filterEnabled = state == .enabled
        filterStep.setStatus(
            done: filterEnabled,
            detail: filterEnabled
                ? String(localized: "The content filter is on.")
                : String(localized: "macOS asks once to allow YAS to filter network content."))
        filterStep.button.isHidden = filterEnabled
        filterStep.button.isEnabled = state == .disabled

        modeStep.setStatus(done: true, detail: store.mode.summary)
        if let index = modePopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == store.mode.rawValue }) {
            modePopUp.selectItem(at: index)
        }
    }

    @objc private func move(_ sender: Any?) {
        extensionManager.offerMoveToApplications()
    }

    @objc private func installOrOpenSettings(_ sender: Any?) {
        switch extensionManager.state {
        case .needsUserApproval, .activating, .enabled, .disabled:
            extensionManager.openSystemSettings()
        default:
            extensionManager.install()
        }
    }

    @objc private func enableFilter(_ sender: Any?) {
        extensionManager.enableFilter()
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let mode = FilterMode(rawValue: raw) else { return }
        store.setMode(mode)
    }

    @objc private func finish(_ sender: Any?) {
        close()
    }
}
