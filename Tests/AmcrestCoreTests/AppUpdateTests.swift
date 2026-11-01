import XCTest
@testable import AmcrestCore

final class AppUpdateTests: XCTestCase {
    func testLeVersaoDoPlist() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.7.0</string></dict></plist>
        """
        XCTAssertEqual(AppUpdate.version(fromInfoPlist: Data(xml.utf8)), "0.7.0")
        XCTAssertNil(AppUpdate.version(fromInfoPlist: Data("lixo".utf8)))
    }

    func testComparacao() {
        XCTAssertEqual(AppUpdate.compare(installed: "0.6.1", published: "0.7.0"),
                       .available(installed: "0.6.1", published: "0.7.0"))
        XCTAssertEqual(AppUpdate.compare(installed: "0.6.1", published: "0.6.1"), .upToDate(installed: "0.6.1"))
        XCTAssertEqual(AppUpdate.compare(installed: "0.6.1", published: "0.1.0"),
                       .aheadOfPublished(installed: "0.6.1", published: "0.1.0"))
    }

    func testMostrarNovidades() {
        XCTAssertTrue(AppUpdate.shouldShowWhatsNew(lastSeen: nil, installed: "0.6.2"))
        XCTAssertTrue(AppUpdate.shouldShowWhatsNew(lastSeen: "0.6.1", installed: "0.6.2"))
        XCTAssertFalse(AppUpdate.shouldShowWhatsNew(lastSeen: "0.6.2", installed: "0.6.2"))
    }

    func testNovidadesDesdeAUltima() {
        let all = [
            Release(version: "0.7.0", date: "2026-11-02", title: "", changes: ["c"]),
            Release(version: "0.6.2", date: "2026-11-01", title: "", changes: ["b"]),
            Release(version: "0.6.1", date: "2026-11-01", title: "", changes: ["a"]),
        ]
        XCTAssertEqual(AppUpdate.releasesSince("0.6.1", upTo: "0.6.2", in: all).map(\.version), ["0.6.2"])
        XCTAssertEqual(AppUpdate.releasesSince(nil, upTo: "0.6.2", in: all).map(\.version), ["0.6.2"])
        XCTAssertEqual(AppUpdate.releasesSince("0.6.0", upTo: "0.7.0", in: all).map(\.version), ["0.7.0", "0.6.2", "0.6.1"])
    }

    func testContagemSaude() {
        let c = CameraHealth.counts([.live, .failed, .failed, .unknown])
        XCTAssertEqual(c.map(\.0), [.live, .failed, .unknown])
        XCTAssertEqual(c.map(\.1), [1, 2, 1])
    }
}
