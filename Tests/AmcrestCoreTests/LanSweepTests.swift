import XCTest
@testable import AmcrestCore

final class LanSweepTests: XCTestCase {
    func testFaixaSemOProprioIP() {
        let h = LanSweep.hosts(inSubnetOf: "192.168.20.5")
        XCTAssertEqual(h.count, 253)
        XCTAssertEqual(h.first, "192.168.20.1")
        XCTAssertEqual(h.last, "192.168.20.254")
        XCTAssertFalse(h.contains("192.168.20.5"))
    }

    func testIPInvalido() {
        XCTAssertTrue(LanSweep.hosts(inSubnetOf: "abc").isEmpty)
        XCTAssertTrue(LanSweep.hosts(inSubnetOf: "300.1.1.1").isEmpty)
    }

    func testVariasInterfacesSemRepetir() {
        let h = LanSweep.hosts(inSubnetsOf: ["10.0.1.2", "10.0.1.9", "192.168.20.5"])
        XCTAssertEqual(h.count, 254 + 253)
        XCTAssertEqual(Set(h).count, h.count)
    }

    func testPortas() {
        XCTAssertEqual(LanSweep.httpPorts(preferred: nil), [80])
        XCTAssertEqual(LanSweep.httpPorts(preferred: 80), [80])
        XCTAssertEqual(LanSweep.httpPorts(preferred: 37777), [80])
        XCTAssertEqual(LanSweep.httpPorts(preferred: 8080), [80, 8080])
    }

    func testSerialDoRealm() {
        XCTAssertEqual(LanSweep.serialFromAuthHeader(#"Digest realm="Login to U0WI4100062MC", qop="auth", nonce="1""#),
                       "U0WI4100062MC")
        XCTAssertEqual(LanSweep.serialFromAuthHeader(#"Basic realm="login to AMC0ABC""#), "AMC0ABC")
        XCTAssertNil(LanSweep.serialFromAuthHeader(#"Digest realm="IP Camera""#))
        XCTAssertNil(LanSweep.serialFromAuthHeader("Digest nonce=1"))
    }
}
