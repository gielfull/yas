import XCTest
@testable import YAS

/// Lookups against the real DB-IP Lite database bundled by scripts/fetch-geoip.sh.
/// Skipped when the database has not been downloaded.
final class GeoIPDatabaseTests: XCTestCase {
    private func realDatabase() throws -> MMDBReader {
        // Tests are hosted by the app, so Bundle.main is YAS.app.
        let sourceCopy = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("YAS/Resources/GeoIP/dbip-country-lite.mmdb")
        let url = GeoIPService.bundledDatabaseURL()
            ?? (FileManager.default.fileExists(atPath: sourceCopy.path) ? sourceCopy : nil)
        guard let url else { throw XCTSkip("dbip-country-lite.mmdb not present; run scripts/fetch-geoip.sh") }
        return try MMDBReader(contentsOf: url)
    }

    func testDatabaseIsBundledInTheApp() throws {
        _ = try realDatabase()
        XCTAssertNotNil(GeoIPService.bundledDatabaseURL(), "database exists in the source tree but is not in the app bundle")
    }

    func testMetadataLooksLikeDBIPCountry() throws {
        let reader = try realDatabase()
        XCTAssertEqual(reader.metadata.ipVersion, 6)
        XCTAssertTrue(reader.metadata.databaseType.lowercased().contains("country"), reader.metadata.databaseType)
        XCTAssertGreaterThan(reader.metadata.nodeCount, 100_000)
    }

    func testRealLookups() throws {
        let reader = try realDatabase()
        XCTAssertEqual(reader.countryCode(for: "8.8.8.8"), "US")
        let cloudflare = try XCTUnwrap(reader.countryCode(for: "1.1.1.1"))
        XCTAssertNotNil(CountryCentroids.centroid(for: cloudflare), "\(cloudflare) is not a known country")
        let googleV6 = try XCTUnwrap(reader.countryCode(for: "2a00:1450::"))
        XCTAssertNotNil(CountryCentroids.centroid(for: googleV6), "\(googleV6) is not a known country")
        XCTAssertNil(reader.countryCode(for: "10.0.0.1"))
        XCTAssertNil(reader.countryCode(for: "192.168.1.1"))
    }

    @MainActor
    func testServiceLoadsBundledDatabase() throws {
        _ = try realDatabase()
        let geo = GeoIPService()
        XCTAssertTrue(geo.isDatabaseLoaded)
        XCTAssertEqual(geo.countryCode(forIP: "8.8.8.8"), "US")
        XCTAssertNotNil(geo.databaseBuildDate)
    }
}
