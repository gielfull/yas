import XCTest
@testable import YAS

final class MMDBReaderTests: XCTestCase {
    private func ipv4Database(recordSize: Int) throws -> MMDBReader {
        let data = MMDBFixture.build(ipVersion: 4, recordSize: recordSize, networks: [
            .init(address: [1, 0, 0, 0], prefix: 8, record: MMDBFixture.country("AU")),
            .init(address: [8, 8, 0, 0], prefix: 16, record: MMDBFixture.country("US")),
            .init(address: [192, 0, 2, 128], prefix: 25, record: MMDBFixture.country("es")),
        ])
        return try MMDBReader(data: data)
    }

    func testIPv4LookupsForEveryRecordSize() throws {
        for recordSize in [24, 28, 32] {
            let reader = try ipv4Database(recordSize: recordSize)
            XCTAssertEqual(reader.metadata.recordSize, recordSize)
            XCTAssertEqual(reader.metadata.ipVersion, 4)
            XCTAssertEqual(reader.metadata.databaseType, "Test-Country")
            XCTAssertEqual(reader.countryCode(for: "1.2.3.4"), "AU", "record size \(recordSize)")
            XCTAssertEqual(reader.countryCode(for: "1.255.255.255"), "AU")
            XCTAssertEqual(reader.countryCode(for: "8.8.8.8"), "US")
            XCTAssertNil(reader.countryCode(for: "8.9.0.1"))
            XCTAssertEqual(reader.countryCode(for: "192.0.2.200"), "ES", "codes are uppercased")
            XCTAssertNil(reader.countryCode(for: "192.0.2.1"))
            XCTAssertNil(reader.countryCode(for: "2001:db8::1"), "IPv6 address in an IPv4 tree")
            XCTAssertNil(reader.countryCode(for: "not an ip"))
        }
    }

    func testIPv6TreeFindsIPv4UnderIPv4MappedPrefix() throws {
        let v4InV6 = [UInt8](repeating: 0, count: 12) + [9, 9, 0, 0]
        let v6: [UInt8] = [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 12)
        let data = MMDBFixture.build(ipVersion: 6, recordSize: 28, networks: [
            .init(address: v4InV6, prefix: 96 + 16, record: MMDBFixture.country("CH")),
            .init(address: v6, prefix: 32, record: MMDBFixture.country("DE")),
        ])
        let reader = try MMDBReader(data: data)
        XCTAssertEqual(reader.countryCode(for: "9.9.9.9"), "CH")
        XCTAssertEqual(reader.countryCode(for: "::ffff:9.9.1.1"), "CH", "IPv4-mapped IPv6")
        XCTAssertEqual(reader.countryCode(for: "2001:db8::1"), "DE")
        XCTAssertEqual(reader.countryCode(for: "[2001:db8:ffff::1%en0]"), "DE")
        XCTAssertNil(reader.countryCode(for: "2001:db9::1"))
        XCTAssertNil(reader.countryCode(for: "10.0.0.1"))
    }

    func testPointersAndRegisteredCountryFallback() throws {
        // Data section starts with a shared "JP" string that records point to.
        let shared = MMDBFixture.encode(.string("JP"))
        let viaPointer: MMDBFixture.Value = .map([("country", .map([("iso_code", .pointer(0))]))])
        let registeredOnly: MMDBFixture.Value = .map([("registered_country", .map([("iso_code", .string("KR"))]))])
        let data = MMDBFixture.build(ipVersion: 4, recordSize: 24, networks: [
            .init(address: [20, 0, 0, 0], prefix: 8, record: viaPointer),
            .init(address: [30, 0, 0, 0], prefix: 8, record: registeredOnly),
        ], prefixData: shared)
        let reader = try MMDBReader(data: data)
        XCTAssertEqual(reader.countryCode(for: "20.1.1.1"), "JP")
        XCTAssertEqual(reader.countryCode(for: "30.1.1.1"), "KR")
        XCTAssertEqual(try reader.lookup("20.1.1.1")?["country"]?["iso_code"], .string("JP"))
        XCTAssertEqual(reader.metadata.buildEpoch, 1_700_000_000)
    }

    func testRejectsDataWithoutMetadata() {
        XCTAssertThrowsError(try MMDBReader(data: Data(repeating: 0, count: 64))) { error in
            XCTAssertEqual(error as? MMDBReader.ReaderError, .metadataNotFound)
        }
    }

    func testAddressParsing() {
        XCTAssertEqual(MMDBReader.addressBytes("192.168.1.2"), [192, 168, 1, 2])
        XCTAssertEqual(MMDBReader.addressBytes("::1")?.count, 16)
        XCTAssertNil(MMDBReader.addressBytes("300.1.1.1"))
    }

    @MainActor
    func testGeoIPServiceDegradesWithoutDatabase() {
        let geo = GeoIPService(databaseURL: nil)
        XCTAssertFalse(geo.isDatabaseLoaded)
        XCTAssertNil(geo.countryCode(forIP: "8.8.8.8"))
        geo.registerKnownAddress("8.8.8.8", countryCode: "us")
        XCTAssertEqual(geo.countryCode(forIP: "8.8.8.8"), "US")
        XCTAssertEqual(geo.country(code: "fr")?.name, CountryCentroids.name(for: "FR"))
        XCTAssertNil(geo.country(code: "ZZ"))
    }
}
