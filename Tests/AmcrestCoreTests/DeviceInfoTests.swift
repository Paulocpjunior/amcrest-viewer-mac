import XCTest
@testable import AmcrestCore

final class DeviceInfoTests: XCTestCase {
    let cam = Camera(name: "T", host: "192.168.1.10")

    func testURLMagicBox() {
        XCTAssertEqual(AmcrestEndpoints.magicBox(cam, .softwareVersion)?.absoluteString,
                       "http://192.168.1.10/cgi-bin/magicBox.cgi?action=getSoftwareVersion")
        XCTAssertEqual(AmcrestEndpoints.magicBox(cam, .serialNumber)?.absoluteString,
                       "http://192.168.1.10/cgi-bin/magicBox.cgi?action=getSerialNo")
    }

    func testVersaoComBuild() {
        let v = DahuaResponse.softwareVersion("version=2.420.AC00.18.R,build:2018-09-13\r\n")
        XCTAssertEqual(v?.version, "2.420.AC00.18.R")
        XCTAssertEqual(v?.build, "2018-09-13")
    }

    func testVersaoSemBuild() {
        let v = DahuaResponse.softwareVersion("version=V2.800.0000000.5.R")
        XCTAssertEqual(v?.version, "V2.800.0000000.5.R")
        XCTAssertNil(v?.build)
    }

    func testVersaoVazia() {
        XCTAssertNil(DahuaResponse.softwareVersion(""))
        XCTAssertNil(DahuaResponse.softwareVersion("version="))
    }

    func testValorUnico() {
        XCTAssertEqual(DahuaResponse.singleValue("sn=AMC01853PN52UCB543\r\n", key: "sn"), "AMC01853PN52UCB543")
        XCTAssertEqual(DahuaResponse.singleValue("type=IP2M-841B", key: "type"), "IP2M-841B")
        XCTAssertEqual(DahuaResponse.singleValue("IP2M-841B", key: "type"), "IP2M-841B")
        XCTAssertNil(DahuaResponse.singleValue("  ", key: "sn"))
    }

    func testFiltro() {
        let cams = [
            Camera(name: "Elevador", host: "10.0.1.72"),
            Camera(name: "Recepção", host: "10.0.1.146", channel: 3),
            Camera(name: "Piscina", host: "192.168.20.8", serialNumber: "AMC0ABC"),
        ]
        XCTAssertEqual(CameraAdmin.filter(cams, query: "").count, 3)
        XCTAssertEqual(CameraAdmin.filter(cams, query: "recepcao").map(\.name), ["Recepção"])
        XCTAssertEqual(CameraAdmin.filter(cams, query: "10.0.1").count, 2)
        XCTAssertEqual(CameraAdmin.filter(cams, query: "amc0abc").map(\.name), ["Piscina"])
    }

    func testRotuloConexao() {
        XCTAssertEqual(CameraAdmin.connectionLabel(Camera(name: "A", host: "10.0.1.72")), "10.0.1.72")
        XCTAssertEqual(CameraAdmin.connectionLabel(Camera(name: "A", host: "10.0.1.146", httpPort: 8080, channel: 3)),
                       "10.0.1.146:8080 · canal 3")
        XCTAssertEqual(CameraAdmin.connectionLabel(Camera(name: "A", host: "")), "sem endereço")
    }
}
