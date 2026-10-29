import AppKit
import MapKit
import YASShared

/// Map page: full-bleed map with arcs from home to every country with active
/// flows, orange country pills, and floating locate/zoom controls. Its pause and
/// map-style buttons ride in the detail pane's top bar (`toolbarAccessory`).
@MainActor
final class MapViewController: NSViewController, DetailPage {
    let pageKind = DetailPageKind.map
    private let toggles = FloatingControlView(cornerRadius: 17)
    var toolbarAccessory: NSView? { _ = view; return toggles }
    static let homeCountryDidChange = Notification.Name("YAS.homeCountryDidChange")

    private let store: Store
    private let mapView = MKMapView()
    private var pauseButton: MapIconButton!
    private var styleButton: MapIconButton!

    private var homeAnnotation: HomeAnnotation?
    private var countryAnnotations: [String: CountryAnnotation] = [:]
    /// Last drawn arcs, to skip redundant overlay rebuilds.
    private var drawnArcs: [String: ArcStyle] = [:]
    private var hasFitInitialRegion = false
    /// Blue wash over satellite imagery (below labels) for the reference's night-blue look.
    private let tint: MKPolygon = {
        var corners = [
            CLLocationCoordinate2D(latitude: 85, longitude: -180),
            CLLocationCoordinate2D(latitude: 85, longitude: 180),
            CLLocationCoordinate2D(latitude: -85, longitude: 180),
            CLLocationCoordinate2D(latitude: -85, longitude: -180),
        ]
        return MKPolygon(coordinates: &corners, count: corners.count)
    }()
    private var apps: [AppSummary] = []

    /// While the map pane is hidden nothing is recomputed; showing it catches up once.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue, !isSuspended, isViewLoaded else { return }
            refreshMap()
        }
    }

    /// App selected in the list; its arcs are highlighted.
    var highlightedAppID: String? {
        didSet {
            guard highlightedAppID != oldValue else { return }
            refreshMap()
        }
    }

    /// Called when the user clicks a country pill.
    var onCountrySelected: ((String) -> Void)?

    private enum ArcStyle: Equatable {
        case normal
        case highlighted
        case dimmed
    }

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsZoomControls = false
        mapView.showsCompass = false
        mapView.showsPitchControl = false
        mapView.showsScale = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.register(ServerAnnotationView.self, forAnnotationViewWithReuseIdentifier: ServerAnnotationView.reuseIdentifier)
        mapView.register(CountryPillAnnotationView.self, forAnnotationViewWithReuseIdentifier: CountryPillAnnotationView.reuseIdentifier)
        container.addSubview(mapView)

        // Pause + map style group (placed by the detail pane's top bar).
        pauseButton = MapIconButton(
            symbol: "hand.raised.slash.fill", toolTip: String(localized: "Pause live updates"),
            target: self, action: #selector(togglePause(_:)))
        styleButton = MapIconButton(
            symbol: "map.fill", toolTip: String(localized: "Switch map style"),
            target: self, action: #selector(toggleMapStyle(_:)))
        toggles.addSubview(pauseButton)
        toggles.addSubview(styleButton)

        let locateBackground = FloatingControlView(cornerRadius: 9)
        let locateButton = MapIconButton(
            symbol: "location.fill", pointSize: 14, toolTip: String(localized: "Center on my location"),
            target: self, action: #selector(recenter(_:)))
        locateBackground.addSubview(locateButton)
        let zoom = ZoomControlView(target: self, zoomIn: #selector(zoomIn(_:)), zoomOut: #selector(zoomOut(_:)))

        for view in [locateBackground, zoom] as [NSView] { container.addSubview(view) }

        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: container.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            toggles.heightAnchor.constraint(equalToConstant: 34),
            pauseButton.leadingAnchor.constraint(equalTo: toggles.leadingAnchor, constant: 10),
            pauseButton.centerYAnchor.constraint(equalTo: toggles.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: 26),
            pauseButton.heightAnchor.constraint(equalToConstant: 26),
            styleButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 6),
            styleButton.centerYAnchor.constraint(equalTo: toggles.centerYAnchor),
            styleButton.widthAnchor.constraint(equalToConstant: 26),
            styleButton.heightAnchor.constraint(equalToConstant: 26),
            styleButton.trailingAnchor.constraint(equalTo: toggles.trailingAnchor, constant: -10),

            zoom.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            zoom.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -44),
            locateBackground.trailingAnchor.constraint(equalTo: zoom.trailingAnchor),
            locateBackground.bottomAnchor.constraint(equalTo: zoom.topAnchor, constant: -12),
            locateBackground.widthAnchor.constraint(equalToConstant: 36),
            locateBackground.heightAnchor.constraint(equalToConstant: 36),
            locateButton.leadingAnchor.constraint(equalTo: locateBackground.leadingAnchor),
            locateButton.trailingAnchor.constraint(equalTo: locateBackground.trailingAnchor),
            locateButton.topAnchor.constraint(equalTo: locateBackground.topAnchor),
            locateButton.bottomAnchor.constraint(equalTo: locateBackground.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyMapStyle(Preferences.mapStyle)
        placeHome()
        mapView.setRegion(Self.region(around: store.geo.homeCountry.coordinate), animated: false)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(homeChanged), name: Self.homeCountryDidChange, object: nil)
        center.addObserver(self, selector: #selector(liveUpdatesChanged), name: Store.flowsDidChange, object: store)
    }

    // MARK: - Data

    /// Called by the split view controller with the list's current apps.
    func update(apps: [AppSummary]) {
        self.apps = apps
        refreshMap()
    }

    private func refreshMap() {
        guard !isSuspended else { return }
        let home = store.geo.homeCountry

        // Countries with active flows, with connection counts and the apps using them.
        var counts: [String: Int] = [:]
        var appsByCountry: [String: Set<String>] = [:]
        for app in apps {
            // The list is already scoped to the time window; the map shows the same rows.
            for destination in app.destinations {
                guard let code = destination.countryCode else { continue }
                counts[code, default: 0] += destination.count
                appsByCountry[code, default: []].insert(app.id)
            }
        }

        // Pills.
        for (code, annotation) in countryAnnotations where counts[code] == nil {
            mapView.removeAnnotation(annotation)
            countryAnnotations[code] = nil
        }
        for (code, count) in counts {
            if let existing = countryAnnotations[code] {
                existing.connectionCount = count
                (mapView.view(for: existing) as? CountryPillAnnotationView)?.update()
            } else if let country = store.geo.country(code: code) {
                let annotation = CountryAnnotation(
                    code: code, name: country.name, coordinate: country.coordinate,
                    connectionCount: count, isHome: code == home.code)
                countryAnnotations[code] = annotation
                mapView.addAnnotation(annotation)
            }
        }

        // Arcs (none for the home country itself).
        var arcs: [String: ArcStyle] = [:]
        for code in counts.keys where code != home.code && countryAnnotations[code] != nil {
            if let selected = highlightedAppID {
                arcs[code] = appsByCountry[code]?.contains(selected) == true ? .highlighted : .dimmed
            } else {
                arcs[code] = .normal
            }
        }
        if arcs != drawnArcs {
            mapView.removeOverlays(mapView.overlays(in: .aboveLabels))
            for (code, style) in arcs.sorted(by: { $0.value == .highlighted ? false : $1.value == .highlighted }) {
                guard let destination = countryAnnotations[code]?.coordinate else { continue }
                var coordinates = [home.coordinate, destination]
                let arc = MKGeodesicPolyline(coordinates: &coordinates, count: coordinates.count)
                arc.title = code
                arc.subtitle = "\(style)"
                mapView.addOverlay(arc, level: .aboveLabels)
            }
            drawnArcs = arcs
        }

        if !hasFitInitialRegion, !arcs.isEmpty {
            hasFitInitialRegion = true
            fitArcs()
        }
    }

    private func placeHome() {
        let home = store.geo.homeCountry
        if let homeAnnotation { mapView.removeAnnotation(homeAnnotation) }
        let annotation = HomeAnnotation(
            coordinate: home.coordinate,
            title: String(format: String(localized: "This Mac (%@)"), home.name))
        homeAnnotation = annotation
        mapView.addAnnotation(annotation)
    }

    private func fitArcs() {
        var rect = MKMapRect.null
        let home = store.geo.homeCountry.coordinate
        // Far-away destinations (e.g. Japan from the Americas) would make the rect wider
        // than the map can show, and MapKit would push home off-screen. Their pills
        // stay reachable by zooming out.
        let nearby = countryAnnotations.values.map(\.coordinate).filter { abs($0.longitude - home.longitude) <= 150 }
        for coordinate in [home] + nearby {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        guard !rect.isNull else { return }
        let padding = NSEdgeInsets(top: 110, left: 90, bottom: 110, right: 110)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: true)
    }

    private static func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 70, longitudeDelta: 100))
    }

    // MARK: - Actions

    @objc private func togglePause(_ sender: Any?) {
        store.setLiveUpdatesPaused(!store.isLiveUpdatesPaused)
    }

    @objc private func toggleMapStyle(_ sender: Any?) {
        let next: MapStyle = Preferences.mapStyle == .satellite ? .dark : .satellite
        Preferences.mapStyle = next
        applyMapStyle(next)
    }

    @objc private func recenter(_ sender: Any?) {
        mapView.setRegion(Self.region(around: store.geo.homeCountry.coordinate), animated: true)
    }

    @objc private func zoomIn(_ sender: Any?) {
        zoom(by: 0.5)
    }

    @objc private func zoomOut(_ sender: Any?) {
        zoom(by: 2)
    }

    private func zoom(by factor: Double) {
        var region = mapView.region
        region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.5), 170)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.5), 360)
        mapView.setRegion(region, animated: true)
    }

    private func applyMapStyle(_ style: MapStyle) {
        switch style {
        case .satellite:
            mapView.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
            styleButton.setSymbol("map.fill")
            if !mapView.overlays(in: .aboveRoads).contains(where: { $0 === tint }) {
                mapView.addOverlay(tint, level: .aboveRoads)
            }
        case .dark:
            mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            styleButton.setSymbol("globe.americas.fill")
            mapView.removeOverlay(tint)
        }
        mapView.appearance = NSAppearance(named: .darkAqua)
    }

    @objc private func homeChanged() {
        placeHome()
        for annotation in countryAnnotations.values { mapView.removeAnnotation(annotation) }
        countryAnnotations.removeAll()
        drawnArcs.removeAll()
        refreshMap()
    }

    @objc private func liveUpdatesChanged() {
        let paused = store.isLiveUpdatesPaused
        pauseButton.setSymbol(paused ? "hand.raised.fill" : "hand.raised.slash.fill")
        pauseButton.contentTintColor = paused ? Theme.pillOrange : .white
        let label = paused ? String(localized: "Resume live updates") : String(localized: "Pause live updates")
        pauseButton.toolTip = label
        pauseButton.setAccessibilityLabel(label)
    }
}

extension MapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is HomeAnnotation {
            return mapView.dequeueReusableAnnotationView(withIdentifier: ServerAnnotationView.reuseIdentifier, for: annotation)
        }
        if annotation is CountryAnnotation {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: CountryPillAnnotationView.reuseIdentifier, for: annotation)
            (view as? CountryPillAnnotationView)?.update()
            return view
        }
        return nil
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polygon = overlay as? MKPolygon {
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = Theme.mapTint
            return renderer
        }
        guard let arc = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: arc)
        renderer.lineCap = .round
        switch arc.subtitle {
        case "\(ArcStyle.highlighted)":
            renderer.strokeColor = Theme.arcHighlighted
            renderer.lineWidth = 3.5
        case "\(ArcStyle.dimmed)":
            renderer.strokeColor = Theme.arcDimmed
            renderer.lineWidth = 2
        default:
            renderer.strokeColor = Theme.arc
            renderer.lineWidth = 2.5
        }
        return renderer
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let annotation = view.annotation else { return }
        if let country = annotation as? CountryAnnotation {
            onCountrySelected?(country.name)
        }
        mapView.deselectAnnotation(annotation, animated: false)
    }
}
