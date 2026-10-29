import CoreLocation
import Foundation
import os

/// IP -> country via the bundled DB-IP Lite Country database, plus the home
/// location used as the near end of the map arcs.
///
/// Without `Resources/GeoIP/dbip-country-lite.mmdb` (see scripts/fetch-geoip.sh)
/// every lookup returns nil and the UI shows "unknown country".
@MainActor
final class GeoIPService {
    struct Country: Hashable, Sendable {
        let code: String
        let name: String
        let coordinate: CLLocationCoordinate2D

        static func == (lhs: Country, rhs: Country) -> Bool { lhs.code == rhs.code }
        func hash(into hasher: inout Hasher) { hasher.combine(code) }
    }

    nonisolated static let databaseResourceName = "dbip-country-lite"

    private let reader: MMDBReader?
    private var cache: [String: String] = [:]
    private var misses: Set<String> = []
    private var knownAddresses: [String: String] = [:]
    private let logger = Logger(subsystem: "com.gful.yas", category: "GeoIP")

    var isDatabaseLoaded: Bool { reader != nil }
    var databaseBuildDate: Date? {
        guard let epoch = reader?.metadata.buildEpoch, epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    init(databaseURL: URL? = GeoIPService.bundledDatabaseURL()) {
        guard let databaseURL else {
            reader = nil
            logger.notice("No GeoIP database bundled; countries will be unknown")
            return
        }
        do {
            reader = try MMDBReader(contentsOf: databaseURL)
        } catch {
            reader = nil
            logger.error("Could not open GeoIP database: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func bundledDatabaseURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: databaseResourceName, withExtension: "mmdb")
            ?? bundle.url(forResource: databaseResourceName, withExtension: "mmdb", subdirectory: "GeoIP")
    }

    // MARK: - Lookup

    func countryCode(forIP ip: String) -> String? {
        if let known = knownAddresses[ip] { return known }
        if let cached = cache[ip] { return cached }
        if misses.contains(ip) { return nil }
        guard let reader else { return nil }

        if cache.count + misses.count > 50_000 {
            cache.removeAll(keepingCapacity: true)
            misses.removeAll(keepingCapacity: true)
        }
        if let code = reader.countryCode(for: ip) {
            cache[ip] = code
            return code
        }
        misses.insert(ip)
        return nil
    }

    func country(code: String) -> Country? {
        let code = code.uppercased()
        guard let centroid = CountryCentroids.centroid(for: code) else { return nil }
        return Country(
            code: code,
            name: CountryCentroids.name(for: code),
            coordinate: CLLocationCoordinate2D(latitude: centroid.latitude, longitude: centroid.longitude)
        )
    }

    /// Pins a country for an address, bypassing the database. Used by the demo data source.
    func registerKnownAddress(_ ip: String, countryCode: String) {
        knownAddresses[ip] = countryCode.uppercased()
    }

    // MARK: - Home

    /// Where the map arcs start: the user's override, else the country of the
    /// Mac's time zone, else its region setting.
    var homeCountry: Country {
        let candidates = [
            Preferences.homeCountryOverride,
            Self.countryCode(forTimeZone: TimeZone.current.identifier),
            Locale.current.region?.identifier,
            "US",
        ]
        for case let code? in candidates {
            if let country = country(code: code) { return country }
        }
        return Country(code: "US", name: "United States", coordinate: CLLocationCoordinate2D(latitude: 37.09, longitude: -95.71))
    }

    var automaticHomeCountryCode: String? {
        Self.countryCode(forTimeZone: TimeZone.current.identifier) ?? Locale.current.region?.identifier
    }

    /// Country for an Olson time zone name, from the system's zone.tab.
    nonisolated static func countryCode(forTimeZone identifier: String) -> String? {
        zoneTable[identifier]
    }

    private nonisolated static let zoneTable: [String: String] = {
        guard let text = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else {
            return [:]
        }
        var table: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3 else { continue }
            table[String(fields[2])] = String(fields[0])
        }
        return table
    }()
}
