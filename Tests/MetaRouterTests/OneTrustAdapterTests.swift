import XCTest
@testable import MetaRouter

final class OneTrustAdapterTests: XCTestCase {

    // MARK: - Category map shape

    func testAllAllowInvertsToAllFalse() {
        let consent = OneTrustAdapter.normalize(["C0001": 1, "C0002": 1, "C0004": 1], explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": false, "c0004": false])
        XCTAssertTrue(consent.explicit)
    }

    func testAllDenyInvertsToAllTrue() {
        let consent = OneTrustAdapter.normalize(["C0001": 0, "C0002": 0, "C0004": 0], explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": true, "c0002": true, "c0004": true])
    }

    func testPartialConsent() {
        let consent = OneTrustAdapter.normalize(["C0001": 1, "C0002": 0, "C0004": 1], explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": true, "c0004": false])
    }

    func testKeysAreLowercasedAndTrimmed() {
        let consent = OneTrustAdapter.normalize([" C0004 ": 1, "c0002": 0, "": 1], explicit: false)

        XCTAssertEqual(consent.optOut, ["c0004": false, "c0002": true], "blank key dropped")
    }

    func testExplicitPassesThroughUnchanged() {
        XCTAssertTrue(OneTrustAdapter.normalize(["C0001": 1], explicit: true).explicit)
        XCTAssertFalse(OneTrustAdapter.normalize(["C0001": 1], explicit: false).explicit)
    }

    func testEmptyInputYieldsEmptyOptOut() {
        XCTAssertEqual(OneTrustAdapter.normalize([:], explicit: false).optOut, [:])
    }

    func testTimestampIsLeftForTheSdkToStamp() {
        XCTAssertNil(OneTrustAdapter.normalize(["C0001": 1], explicit: true).timestamp)
    }

    // MARK: - Value representations

    func testBoolNumberAndStringRepresentationsOfConsented() {
        let raw: [String: Any] = [
            "a": true, "b": 1, "c": 1.0, "d": NSNumber(value: 1),
            "e": "1", "f": "true", "g": "TRUE", "h": " 1 ",
        ]

        let consent = OneTrustAdapter.normalize(raw, explicit: true)

        for key in raw.keys {
            XCTAssertEqual(consent.optOut[key], false, "\(key) must read as consented → optOut false")
        }
    }

    func testBoolNumberAndStringRepresentationsOfNotConsented() {
        let raw: [String: Any] = [
            "a": false, "b": 0, "c": 0.0, "d": NSNumber(value: 0),
            "e": "0", "f": "false", "g": "FALSE", "h": "",
        ]

        let consent = OneTrustAdapter.normalize(raw, explicit: true)

        for key in raw.keys {
            XCTAssertEqual(consent.optOut[key], true, "\(key) must read as not consented → optOut true")
        }
    }

    /// An unreadable signal never opts a user in.
    func testUnreadableValuesCountAsOptedOut() {
        let raw: [String: Any] = [
            "a": 2, "b": -1, "c": "yes", "d": "on", "e": NSNull(), "f": [1], "g": ["x": 1], "h": "1.0",
        ]

        let consent = OneTrustAdapter.normalize(raw, explicit: true)

        for key in raw.keys {
            XCTAssertEqual(consent.optOut[key], true, "\(key) must degrade to opted out")
        }
    }

    /// Values parsed from JSON arrive as NSNumber; 0/1 bridge to Bool and must still
    /// read as a status, while other numbers must not read as consented.
    func testJsonSourcedValues() throws {
        let json = #"{"C0001":1,"C0002":0,"C0003":true,"C0004":false,"C0005":7}"#
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        let consent = OneTrustAdapter.normalize(raw, explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": true, "c0003": false, "c0004": true, "c0005": true])
    }

    // MARK: - OptanonConsent groups string

    func testGroupsStringParses() {
        let consent = OneTrustAdapter.normalize(groups: "C0001:1,C0002:0,C0004:1", explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": true, "c0004": false])
    }

    /// Segment by segment: surrounding whitespace is fine; an empty segment, a
    /// segment with no colon, and a segment with an empty key are skipped; a value
    /// that is not a status ("1:extra", "") reads as not consented.
    func testGroupsStringToleratesWhitespaceAndMalformedSegments() {
        let consent = OneTrustAdapter.normalize(
            groups: " C0001 : 1 , C0002:0,, garbage ,:1, C0004:1:extra ,C0005:",
            explicit: true
        )

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": true, "c0004": true, "c0005": true])
    }

    /// What a cookie store actually hands back: still percent-encoded. Without the
    /// decode this parsed to zero segments, and reconcile then stamped every
    /// registered category as explicitly opted out.
    func testPercentEncodedGroupsValueIsDecoded() {
        let consent = OneTrustAdapter.normalize(groups: "C0001%3A1%2CC0002%3A1%2CC0004%3A0", explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": false, "c0004": true])
    }

    func testWholeOptanonConsentCookieValueIsAccepted() {
        let cookie = "isGpcEnabled=0&datestamp=Mon+Oct+05+2026&version=202409.1.0&groups=C0001%3A1%2CC0002%3A0%2CC0004%3A1&AwaitingReconsent=false"

        let consent = OneTrustAdapter.normalize(groups: cookie, explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": true, "c0004": false])
    }

    func testDecodedWholeCookieValueIsAccepted() {
        let consent = OneTrustAdapter.normalize(groups: "datestamp=x&groups=C0001:1,C0004:0&version=1", explicit: false)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0004": true])
    }

    /// A full document.cookie string: another cookie carrying a raw `%` must not
    /// break the decode of the groups value, and a groups-last cookie must not
    /// swallow the next cookie into its final category.
    func testCookieJarWithStrayPercentAndGroupsLast() {
        let jar = "promo=100%; OptanonConsent=isGpcEnabled=0&groups=C0001%3A1%2CC0002%3A1%2CC0004%3A1; _ga=GA1.1.123.456"

        let consent = OneTrustAdapter.normalize(groups: jar, explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0002": false, "c0004": false])
    }

    /// An encoded `&` or `groups=` inside another parameter must not become a live
    /// delimiter — only the groups token's own value is decoded.
    func testEncodedDelimitersInOtherParametersAreIgnored() {
        let cookie = "landingPath=https%3A%2F%2Fx.com%2F%3Fgroups%3Dabc%26y%3D1&groups=C0001%3A1%2CC0004%3A0&version=1"

        let consent = OneTrustAdapter.normalize(groups: cookie, explicit: true)

        XCTAssertEqual(consent.optOut, ["c0001": false, "c0004": true])
    }

    func testPresentButEmptyGroupsParameterYieldsEmptyOptOut() {
        XCTAssertEqual(OneTrustAdapter.normalize(groups: "isGpcEnabled=0&groups=&AwaitingReconsent=false", explicit: true).optOut, [:])
    }

    /// A `name=` prefix is not a group ID; the segment is dropped rather than
    /// minted as a category nobody registered.
    func testNamePrefixedSegmentIsDropped() {
        let consent = OneTrustAdapter.normalize(groups: "OptanonConsent=C0001:1,C0002:0", explicit: true)

        XCTAssertEqual(consent.optOut, ["c0002": true])
    }

    func testNonIntegralFloatIsNotConsented() {
        let raw: [String: Any] = ["a": Float(1.5), "b": CGFloat(1.5), "c": Float(1), "d": Int8(1), "e": Int64(0)]

        let consent = OneTrustAdapter.normalize(raw, explicit: true)

        XCTAssertEqual(consent.optOut, ["a": true, "b": true, "c": false, "d": false, "e": true])
    }

    func testEmptyGroupsStringYieldsEmptyOptOut() {
        XCTAssertEqual(OneTrustAdapter.normalize(groups: "", explicit: false).optOut, [:])
    }

    // MARK: - End to end through the SDK's reconcile

    func testOutputRoundTripsThroughSetConsent() {
        let suite = "com.metarouter.test.oneTrustRoundTrip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ConsentManager(storage: ConsentStorage(userDefaults: defaults), dispatch: { $0() })
        manager.registerConsentCategories([
            ConsentCategory(key: "c0001", defaultOptOut: false),
            ConsentCategory(key: "c0002"),
            ConsentCategory(key: "c0004"),
        ])

        // OneTrust reports two of the three registered categories plus one nobody tracks.
        manager.setConsent(OneTrustAdapter.normalize(["C0002": 1, "C0004": 0, "C0099": 1], explicit: true))

        XCTAssertEqual(manager.getConsent().optOut, ["c0001": false, "c0002": false, "c0004": true],
                       "adapter translates, setConsent reconciles: unknown dropped, missing filled")
        XCTAssertTrue(manager.getConsent().explicit)
    }
}
