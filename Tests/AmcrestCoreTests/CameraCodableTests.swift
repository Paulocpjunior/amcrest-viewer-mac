import XCTest
@testable import AmcrestCore

final class CameraCodableTests: XCTestCase {

    /// Cadastro antigo, gravado antes do campo `serial`, deve decodificar com serial vazio.
    func testDecodesLegacyJSONWithoutSerial() throws {
        let json = """
        {"id":"8A7D0B2E-1F3C-4A5B-9C6D-0E1F2A3B4C5D",
         "name":"Garagem","host":"192.168.1.10","httpPort":80,
         "rtspPort":554,"channel":1,"username":"admin","useHTTPS":false}
        """.data(using: .utf8)!
        let cam = try JSONDecoder().decode(Camera.self, from: json)
        XCTAssertEqual(cam.name, "Garagem")
        XCTAssertEqual(cam.serial, "")
    }

    /// O serial é preservado num ciclo de codificar e decodificar.
    func testSerialRoundTrips() throws {
        let cam = Camera(name: "Yellow Front", host: "10.0.1.50", serial: "AMC01858719C691882")
        let data = try JSONEncoder().encode(cam)
        let back = try JSONDecoder().decode(Camera.self, from: data)
        XCTAssertEqual(back.serial, "AMC01858719C691882")
        XCTAssertEqual(back, cam)
    }
}
