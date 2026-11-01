import XCTest
@testable import AmcrestCore

final class DetectionGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testThrottleRespectsInterval() {
        var gate = DetectionGate(analysisInterval: 1.0)
        XCTAssertTrue(gate.shouldAnalyze(now: t0))                 // primeira sempre roda
        XCTAssertFalse(gate.shouldAnalyze(now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(gate.shouldAnalyze(now: t0.addingTimeInterval(1.0)))
    }

    func testHoldKeepsPresentAfterBriefMiss() {
        var gate = DetectionGate(holdWindow: 3.0)
        _ = gate.record(detected: true, now: t0)
        // Um quadro sem detecção logo depois: ainda "presente" pela janela de hold.
        let a = gate.record(detected: false, now: t0.addingTimeInterval(2.0))
        XCTAssertTrue(a.isPresent)
        // Passado o hold, deixa de estar presente.
        let b = gate.record(detected: false, now: t0.addingTimeInterval(3.5))
        XCTAssertFalse(b.isPresent)
    }

    func testEventCooldownFiresOnceThenSuppresses() {
        var gate = DetectionGate(eventCooldown: 15.0)
        XCTAssertTrue(gate.record(detected: true, now: t0).raisedEvent)          // primeiro evento
        XCTAssertFalse(gate.record(detected: true, now: t0.addingTimeInterval(5)).raisedEvent)  // dentro do cooldown
        XCTAssertTrue(gate.record(detected: true, now: t0.addingTimeInterval(16)).raisedEvent)  // passou o cooldown
    }

    func testNoDetectionNeverRaisesEvent() {
        var gate = DetectionGate()
        let a = gate.record(detected: false, now: t0)
        XCTAssertFalse(a.raisedEvent)
        XCTAssertFalse(a.isPresent)
    }
}
