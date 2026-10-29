import AppKit
import MapKit

/// The user's end of every arc.
final class HomeAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?

    init(coordinate: CLLocationCoordinate2D, title: String) {
        self.coordinate = coordinate
        self.title = title
    }
}

/// A destination country with active flows.
final class CountryAnnotation: NSObject, MKAnnotation {
    let code: String
    let name: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var connectionCount: Int
    var isHome: Bool

    var title: String? { name }

    init(code: String, name: String, coordinate: CLLocationCoordinate2D, connectionCount: Int, isHome: Bool) {
        self.code = code
        self.name = name
        self.coordinate = coordinate
        self.connectionCount = connectionCount
        self.isHome = isHome
    }
}

/// Grey disc with a server glyph, drawn at the home location.
final class ServerAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "Server"
    private static let diameter: CGFloat = 40

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        canShowCallout = false
        displayPriority = .required
        zPriority = .max
        wantsLayer = true

        let disc = NSView(frame: bounds)
        disc.wantsLayer = true
        disc.layer?.backgroundColor = NSColor(white: 0.86, alpha: 0.96).cgColor
        disc.layer?.cornerRadius = Self.diameter / 2
        disc.layer?.shadowColor = NSColor.black.cgColor
        disc.layer?.shadowOpacity = 0.35
        disc.layer?.shadowRadius = 4
        disc.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(disc)

        let glyph = NSImageView(frame: bounds.insetBy(dx: 9, dy: 9))
        glyph.image = Theme.symbol("server.rack", pointSize: 17, weight: .semibold)
            ?? Theme.symbol("externaldrive.fill", pointSize: 17, weight: .semibold)
        glyph.contentTintColor = NSColor(white: 0.22, alpha: 1)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)
        toolTip = annotation?.title ?? nil
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(annotation?.title ?? nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Orange capsule with the country name.
final class CountryPillAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "CountryPill"

    private let label = NSTextField(labelWithString: "")

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .rectangle
        wantsLayer = true
        layer?.backgroundColor = Theme.pillOrange.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var annotation: MKAnnotation? {
        didSet { update() }
    }

    func update() {
        guard let country = annotation as? CountryAnnotation else { return }
        label.stringValue = country.name
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 26, height: 28)
        frame.size = size
        label.frame = NSRect(
            x: (size.width - label.frame.width) / 2,
            y: (size.height - label.frame.height) / 2,
            width: label.frame.width,
            height: label.frame.height)
        layer?.cornerRadius = size.height / 2
        // Sit below the home disc when the destination is the home country.
        centerOffset = country.isHome ? CGPoint(x: 0, y: 36) : .zero
        // Overlapping pills: MapKit hides the ones with fewer connections.
        displayPriority = MKFeatureDisplayPriority(rawValue: 500 + Float(min(country.connectionCount, 499)))
        let name = country.name
        let count = country.connectionCount
        toolTip = String(localized: "\(name): \(count) connections")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "\(country.name), \(country.connectionCount) connections. Filters the list."))
    }
}
