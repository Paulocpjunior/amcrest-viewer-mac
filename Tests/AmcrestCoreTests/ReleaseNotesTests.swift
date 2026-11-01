import XCTest
@testable import AmcrestCore

final class ReleaseNotesTests: XCTestCase {
    func testOrdemDaMaisNovaParaAMaisAntiga() {
        let all = ReleaseNotes.all
        XCTAssertFalse(all.isEmpty)
        for (a, b) in zip(all, all.dropFirst()) {
            XCTAssertTrue(ReleaseNotes.isNewer(a.version, than: b.version), "\(a.version) deveria ser > \(b.version)")
            XCTAssertGreaterThanOrEqual(a.date, b.date)
        }
    }

    func testCadaVersaoTemMudancas() {
        for r in ReleaseNotes.all {
            XCTAssertFalse(r.changes.isEmpty, r.version)
            XCTAssertEqual(r.date.count, 10, r.version)
        }
    }

    func testDataBrasileira() {
        XCTAssertEqual(Release(version: "1", date: "2026-11-01", title: "", changes: []).displayDate, "01/11/2026")
    }

    func testComparacao() {
        XCTAssertTrue(ReleaseNotes.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertFalse(ReleaseNotes.isNewer("0.6.0", than: "0.6.0"))
        XCTAssertTrue(ReleaseNotes.isNewer("1.0", than: "0.9.9"))
    }

    /// O Info.plist precisa anunciar a mesma versão que o topo do histórico.
    func testInfoPlistBateComOHistorico() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dict = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(dict["CFBundleShortVersionString"] as? String, ReleaseNotes.latest.version)
    }
}
