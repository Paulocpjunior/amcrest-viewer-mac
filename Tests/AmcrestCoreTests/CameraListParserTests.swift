import XCTest
@testable import AmcrestCore

final class CameraListParserTests: XCTestCase {

    func testIPSimples() {
        let r = CameraListParser.parse("192.168.1.10")
        XCTAssertEqual(r.cameras.count, 1)
        XCTAssertEqual(r.cameras[0].camera.host, "192.168.1.10")
        XCTAssertEqual(r.cameras[0].camera.httpPort, 80)
        XCTAssertEqual(r.cameras[0].camera.name, "192.168.1.10")
        XCTAssertEqual(r.cameras[0].lineNumber, 1)
        XCTAssertTrue(r.rejected.isEmpty)
    }

    func testNomeIPPortaEUsuario() {
        let r = CameraListParser.parse("Garagem dos fundos, 192.168.1.10:8080, admin")
        let c = r.cameras[0].camera
        XCTAssertEqual(c.name, "Garagem dos fundos")
        XCTAssertEqual(c.host, "192.168.1.10")
        XCTAssertEqual(c.httpPort, 8080)
        XCTAssertEqual(c.username, "admin")
    }

    func testIgualECanal() {
        let r = CameraListParser.parse("Portão = 192.168.1.11 canal 2")
        let c = r.cameras[0].camera
        XCTAssertEqual(c.name, "Portão")
        XCTAssertEqual(c.channel, 2)
    }

    func testCanalGrudado() {
        let r = CameraListParser.parse("NVR ch3 192.168.1.50")
        XCTAssertEqual(r.cameras[0].camera.channel, 3)
        XCTAssertEqual(r.cameras[0].camera.name, "NVR")
    }

    func testURLRTSPComSenha() {
        let r = CameraListParser.parse("Sala rtsp://admin:s3nh%40@192.168.1.13:5554/cam/realmonitor?channel=4&subtype=0")
        let p = r.cameras[0]
        XCTAssertEqual(p.camera.name, "Sala")
        XCTAssertEqual(p.camera.host, "192.168.1.13")
        XCTAssertEqual(p.camera.rtspPort, 5554)
        XCTAssertEqual(p.camera.channel, 4)
        XCTAssertEqual(p.camera.username, "admin")
        XCTAssertEqual(p.password, "s3nh@")
    }

    func testURLHTTPS() {
        let r = CameraListParser.parse("https://minhacasa.ddns.net:8443")
        let c = r.cameras[0].camera
        XCTAssertTrue(c.useHTTPS)
        XCTAssertEqual(c.httpPort, 8443)
        XCTAssertEqual(c.host, "minhacasa.ddns.net")
    }

    func testHostname() {
        let r = CameraListParser.parse("Quintal\tcam-quintal.local")
        XCTAssertEqual(r.cameras[0].camera.host, "cam-quintal.local")
        XCTAssertEqual(r.cameras[0].camera.name, "Quintal")
    }

    func testIgnoraComentariosEVazias() {
        let txt = """
        # minhas câmeras

        // outra anotação
        192.168.1.10\r
        192.168.1.11
        """
        let r = CameraListParser.parse(txt)
        XCTAssertEqual(r.cameras.map(\.camera.host), ["192.168.1.10", "192.168.1.11"])
        XCTAssertEqual(r.cameras.map(\.lineNumber), [4, 5])
    }

    func testRejeitaSemEndereco() {
        let r = CameraListParser.parse("câmera da cozinha")
        XCTAssertTrue(r.cameras.isEmpty)
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertEqual(r.rejected[0].lineNumber, 1)
    }

    func testRejeitaIPInvalido() {
        let r = CameraListParser.parse("192.168.1.300")
        XCTAssertTrue(r.cameras.isEmpty)
        XCTAssertEqual(r.rejected.count, 1)
    }

    func testRejeitaDoisEnderecos() {
        let r = CameraListParser.parse("192.168.1.10 192.168.1.11")
        XCTAssertTrue(r.cameras.isEmpty)
        XCTAssertEqual(r.rejected.count, 1)
    }

    func testRejeitaPortaInvalida() {
        let r = CameraListParser.parse("192.168.1.10:99999")
        XCTAssertTrue(r.cameras.isEmpty)
    }

    func testNomePadraoComCanal() {
        let r = CameraListParser.parse("192.168.1.50 canal 2")
        XCTAssertEqual(r.cameras[0].camera.name, "192.168.1.50 · canal 2")
    }

    func testSerialDepoisDoIP() {
        let r = CameraListParser.parse("3016 YLL FRONT 192.168.1.20 sn AMC01853PN52UCB543")
        let c = r.cameras[0].camera
        XCTAssertEqual(c.name, "3016 YLL FRONT")
        XCTAssertEqual(c.host, "192.168.1.20")
        XCTAssertEqual(c.serialNumber, "AMC01853PN52UCB543")
    }

    func testSerialComDoisPontosEIgual() {
        XCTAssertEqual(CameraListParser.parse("Cam 192.168.1.21 S/N:AMC018X166ZL5W937Z").cameras[0].camera.serialNumber,
                       "AMC018X166ZL5W937Z")
        XCTAssertEqual(CameraListParser.parse("Cam 192.168.1.22 serial=Z20CBD8C52AB0").cameras[0].camera.serialNumber,
                       "Z20CBD8C52AB0")
    }

    func testSemSerialFicaNil() {
        XCTAssertNil(CameraListParser.parse("Garagem 192.168.1.10").cameras[0].camera.serialNumber)
    }

    func testRejeitaSoSerialComMotivoClaro() {
        let r = CameraListParser.parse("Yellow Front sn AMC01858719C691882")
        XCTAssertTrue(r.cameras.isEmpty)
        XCTAssertEqual(r.rejected.count, 1)
        XCTAssertTrue(r.rejected[0].reason.contains("S/N AMC01858719C691882"))
    }

    func testListaAntigaSemSerialAindaAbre() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Garagem","host":"192.168.1.10","httpPort":80,"rtspPort":554,"channel":1,"username":"admin","useHTTPS":false}]"#
        let cams = try JSONDecoder().decode([Camera].self, from: Data(json.utf8))
        XCTAssertEqual(cams.count, 1)
        XCTAssertNil(cams[0].serialNumber)
    }
}
