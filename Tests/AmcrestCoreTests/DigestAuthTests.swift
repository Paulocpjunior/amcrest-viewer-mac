import XCTest
@testable import AmcrestCore

final class DigestAuthTests: XCTestCase {
    func testMD5() {
        XCTAssertEqual(MD5Hex.of(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5Hex.of("abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testParseAmcrestChallenge() {
        let h = #"Digest realm="Login to AMC0573E29B1B0150E", qop="auth", nonce="1180736547", opaque="2d2f8a4f9b8e2a40""#
        let c = DigestChallenge.parse(h)
        XCTAssertEqual(c?.realm, "Login to AMC0573E29B1B0150E")
        XCTAssertEqual(c?.nonce, "1180736547")
        XCTAssertEqual(c?.qop, "auth")
        XCTAssertEqual(c?.opaque, "2d2f8a4f9b8e2a40")
    }

    func testParseWithBasicFirstAndUnquotedAlgorithm() {
        let h = #"Basic realm="x", Digest realm="cam", nonce="n1", algorithm=MD5, qop="auth,auth-int""#
        let c = DigestChallenge.parse(h)
        XCTAssertEqual(c?.realm, "cam")
        XCTAssertEqual(c?.algorithm, "MD5")
        XCTAssertNil(DigestChallenge.parse(#"Basic realm="x""#))
    }

    /// Exemplo da RFC 2617, seção 3.5.
    func testRFC2617Response() {
        let c = DigestChallenge(realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                qop: "auth,auth-int", opaque: "5ccc069c403ebaf9f0171e9517f40e41")
        let a = c.authorization(method: "GET", uri: "/dir/index.html", username: "Mufasa",
                                password: "Circle Of Life", nc: 1, cnonce: "0a4f113b")
        XCTAssertTrue(a.contains(#"response="6629fae49393a05397450978507c4ef1""#), a)
        XCTAssertTrue(a.contains("nc=00000001"))
        XCTAssertTrue(a.contains("qop=auth,") || a.contains("qop=auth"))
    }

    func testRequestURIKeepsQuery() {
        let url = URL(string: "http://192.168.20.146/cgi-bin/snapshot.cgi?channel=1")!
        XCTAssertEqual(DigestChallenge.requestURI(url), "/cgi-bin/snapshot.cgi?channel=1")
    }

    func testWebLoginHashAndOutcome() {
        let inner = MD5Hex.of("admin:Login to X:senha").uppercased()
        XCTAssertEqual(WebLogin.passwordHash(username: "admin", password: "senha", realm: "Login to X", random: "123"),
                       MD5Hex.of("admin:123:\(inner)").uppercased())
        XCTAssertEqual(WebLogin.outcome(result: true, code: nil, message: nil), .ok)
        XCTAssertEqual(WebLogin.outcome(result: false, code: 268632081, message: "Account locked"), .locked("Account locked"))
        XCTAssertEqual(WebLogin.outcome(result: false, code: 268632071, message: nil), .wrongPassword)
    }
}
