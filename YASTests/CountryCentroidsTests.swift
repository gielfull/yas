import XCTest
@testable import YAS

final class CountryCentroidsTests: XCTestCase {
    func testTableCoversEveryISOCountryWithSaneCoordinates() throws {
        let all = CountryCentroids.all
        XCTAssertGreaterThanOrEqual(all.count, 249)
        for (code, centroid) in all {
            XCTAssertEqual(code.count, 2, code)
            XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isUppercase }, code)
            XCTAssertTrue((-90...90).contains(centroid.latitude), code)
            XCTAssertTrue((-180...180).contains(centroid.longitude), code)
        }
        // Every code in the system's ISO 3166 table has a centroid.
        let iso = try String(contentsOfFile: "/usr/share/zoneinfo/iso3166.tab", encoding: .utf8)
        let codes = iso.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { $0.split(separator: "\t").first }
        XCTAssertFalse(codes.isEmpty)
        for code in codes {
            XCTAssertNotNil(CountryCentroids.centroid(for: String(code)), "missing \(code)")
        }
    }

    func testKnownCentroidsAreInTheRightPlace() {
        func assertNear(_ code: String, _ lat: Double, _ lng: Double, file: StaticString = #filePath, line: UInt = #line) {
            guard let centroid = CountryCentroids.centroid(for: code) else {
                return XCTFail("missing \(code)", file: file, line: line)
            }
            XCTAssertEqual(centroid.latitude, lat, accuracy: 5, code, file: file, line: line)
            XCTAssertEqual(centroid.longitude, lng, accuracy: 5, code, file: file, line: line)
        }
        assertNear("US", 37, -96)
        assertNear("ES", 40, -4)
        assertNear("JP", 36, 138)
        assertNear("AU", -25, 134)
        assertNear("BR", -14, -52)
        assertNear("CO", 4.5, -74)
        assertNear("ZA", -30, 23)
        XCTAssertNotNil(CountryCentroids.centroid(for: "us"), "lookup is case-insensitive")
    }

    func testNamesAndFlags() {
        XCTAssertEqual(CountryCentroids.name(for: "US", locale: Locale(identifier: "en_US")), "United States")
        XCTAssertEqual(CountryCentroids.name(for: "ES", locale: Locale(identifier: "es_ES")), "España")
        XCTAssertEqual(CountryCentroids.flag(for: "US"), "🇺🇸")
        XCTAssertEqual(CountryCentroids.flag(for: "X"), "")
    }

    func testTimeZoneMapsToCountry() {
        XCTAssertEqual(GeoIPService.countryCode(forTimeZone: "America/Bogota"), "CO")
        XCTAssertEqual(GeoIPService.countryCode(forTimeZone: "Europe/Madrid"), "ES")
        XCTAssertNil(GeoIPService.countryCode(forTimeZone: "Not/AZone"))
    }
}
