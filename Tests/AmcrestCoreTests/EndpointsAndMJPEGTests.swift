import XCTest
@testable import AmcrestCore

final class EndpointsTests: XCTestCase {
    let cam = Camera(name: "T", host: "192.168.1.10", channel: 2)

    func testSnapshot() {
        XCTAssertEqual(AmcrestEndpoints.snapshot(cam)?.absoluteString,
                       "http://192.168.1.10/cgi-bin/snapshot.cgi?channel=2")
    }

    func testMJPEGComPorta() {
        var c = cam
        c.httpPort = 8080
        XCTAssertEqual(AmcrestEndpoints.mjpeg(c)?.absoluteString,
                       "http://192.168.1.10:8080/cgi-bin/mjpg/video.cgi?channel=2&subtype=1")
    }

    func testPTZLimitaVelocidade() {
        let u = AmcrestEndpoints.ptz(cam, .zoomIn, start: true, speed: 99)?.absoluteString
        XCTAssertEqual(u, "http://192.168.1.10/cgi-bin/ptz.cgi?action=start&channel=2&code=ZoomTele&arg1=0&arg2=8&arg3=0")
    }

    func testRTSPSemESenha() {
        XCTAssertEqual(AmcrestEndpoints.rtsp(cam)?.absoluteString,
                       "rtsp://192.168.1.10:554/cam/realmonitor?channel=2&subtype=0")
        let url = AmcrestEndpoints.rtsp(cam, password: "a@b")!
        let comSenha = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comSenha.user, "admin")
        XCTAssertEqual(comSenha.password, "a@b")
    }
}

final class MJPEGFrameExtractorTests: XCTestCase {
    func jpeg(_ body: [UInt8]) -> [UInt8] { [0xFF, 0xD8] + body + [0xFF, 0xD9] }

    func testQuadrosComBoundary() {
        var ex = MJPEGFrameExtractor()
        let f1 = jpeg([1, 2, 3]), f2 = jpeg([4, 5])
        let header = Array("--myboundary\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        let frames = ex.append(Data(header + f1 + Array("\r\n".utf8) + header + f2))
        XCTAssertEqual(frames, [Data(f1), Data(f2)])
    }

    func testQuadroPartidoEmPedacos() {
        var ex = MJPEGFrameExtractor()
        let f = jpeg([9, 9, 9, 9])
        var out: [Data] = []
        for b in f { out += ex.append(Data([b])) }   // um byte por vez, inclusive FF/D8 separados
        XCTAssertEqual(out, [Data(f)])
    }

    func testDescartaBufferGigante() {
        var ex = MJPEGFrameExtractor(maxBufferSize: 16)
        XCTAssertTrue(ex.append(Data([0xFF, 0xD8] + Array(repeating: 0, count: 64))).isEmpty)
        let f = jpeg([7])
        XCTAssertEqual(ex.append(Data(f)), [Data(f)])
    }
}
