import XCTest
@testable import AmcrestCore

final class OnvifDiscoveryTests: XCTestCase {

    /// ProbeMatch típico de uma câmera Amcrest/Dahua, com prefixos de namespace reais.
    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
    <SOAP-ENV:Body>
    <d:ProbeMatches>
    <d:ProbeMatch>
    <d:Types>dn:NetworkVideoTransmitter</d:Types>
    <d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/IPC-Garagem onvif://www.onvif.org/hardware/IP2M-841 onvif://www.onvif.org/serialNumber/AMC01853PN52UCB543</d:Scopes>
    <d:XAddrs>http://192.168.1.20/onvif/device_service</d:XAddrs>
    </d:ProbeMatch>
    </d:ProbeMatches>
    </SOAP-ENV:Body>
    </SOAP-ENV:Envelope>
    """

    func testParseProbeMatchExtraiTudo() {
        let devices = OnvifDiscovery.parseProbeMatch(sample)
        XCTAssertEqual(devices.count, 1)
        let d = devices[0]
        XCTAssertEqual(d.host, "192.168.1.20")
        XCTAssertEqual(d.name, "IPC-Garagem")
        XCTAssertEqual(d.hardware, "IP2M-841")
        XCTAssertEqual(d.serial, "AMC01853PN52UCB543")
        XCTAssertFalse(d.useHTTPS)
        XCTAssertEqual(d.httpPort, 80)
        XCTAssertEqual(d.xaddr, "http://192.168.1.20/onvif/device_service")
        XCTAssertEqual(d.displayName, "IPC-Garagem")
    }

    func testNomePercentEncodedEDecodificado() {
        let xml = """
        <d:ProbeMatch xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
        <d:Scopes>onvif://www.onvif.org/name/Cam%20da%20Piscina</d:Scopes>
        <d:XAddrs>http://10.0.1.72/onvif/device_service</d:XAddrs>
        </d:ProbeMatch>
        """
        let d = OnvifDiscovery.parseProbeMatch(xml)[0]
        XCTAssertEqual(d.name, "Cam da Piscina")
        XCTAssertEqual(d.host, "10.0.1.72")
    }

    func testSemNomeUsaHardwareDepoisHost() {
        let xml = """
        <d:ProbeMatch xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
        <d:Scopes>onvif://www.onvif.org/hardware/NVR4216</d:Scopes>
        <d:XAddrs>http://192.168.20.146/onvif/device_service</d:XAddrs>
        </d:ProbeMatch>
        """
        let d = OnvifDiscovery.parseProbeMatch(xml)[0]
        XCTAssertNil(d.name)
        XCTAssertEqual(d.hardware, "NVR4216")
        XCTAssertEqual(d.displayName, "NVR4216")
    }

    func testVariosXAddrsPegaOPrimeiroHTTP() {
        let xaddrs = "http://192.168.1.50/onvif/device_service https://192.168.1.50/onvif/device_service"
        let r = OnvifDiscovery.firstHTTPEndpoint(in: xaddrs)
        XCTAssertEqual(r?.host, "192.168.1.50")
        XCTAssertEqual(r?.port, 80)
        XCTAssertEqual(r?.useHTTPS, false)
        XCTAssertEqual(r?.xaddr, "http://192.168.1.50/onvif/device_service")
    }

    func testXAddrsSemHTTPFicaNil() {
        XCTAssertNil(OnvifDiscovery.firstHTTPEndpoint(in: "ftp://192.168.1.1/x"))
        XCTAssertNil(OnvifDiscovery.firstHTTPEndpoint(in: ""))
    }

    func testHTTPSComPortaNaoPadraoEPreservado() {
        let xml = """
        <d:ProbeMatch xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
        <d:Scopes>onvif://www.onvif.org/name/Cam-Segura</d:Scopes>
        <d:XAddrs>https://192.168.1.20:8443/onvif/device_service</d:XAddrs>
        </d:ProbeMatch>
        """
        let d = OnvifDiscovery.parseProbeMatch(xml)[0]
        XCTAssertEqual(d.host, "192.168.1.20")
        XCTAssertTrue(d.useHTTPS)
        XCTAssertEqual(d.httpPort, 8443)
    }

    func testPrimeiroMatchSemScopesNaoRoubaDoSegundo() {
        // Finding do Codex: coletar tags global e casar por índice embaralhava os campos.
        // O primeiro aparelho não anuncia Scopes; não pode herdar nome/serial do segundo.
        let xml = """
        <d:Envelope xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
        <d:ProbeMatch>
        <d:XAddrs>http://192.168.1.11/onvif/device_service</d:XAddrs>
        </d:ProbeMatch>
        <d:ProbeMatch>
        <d:Scopes>onvif://www.onvif.org/name/Cam-B onvif://www.onvif.org/serialNumber/SN-B</d:Scopes>
        <d:XAddrs>http://192.168.1.12/onvif/device_service</d:XAddrs>
        </d:ProbeMatch>
        </d:Envelope>
        """
        let devices = OnvifDiscovery.parseProbeMatch(xml)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].host, "192.168.1.11")
        XCTAssertNil(devices[0].name)
        XCTAssertNil(devices[0].serial)
        XCTAssertEqual(devices[1].host, "192.168.1.12")
        XCTAssertEqual(devices[1].name, "Cam-B")
        XCTAssertEqual(devices[1].serial, "SN-B")
    }

    func testDoisProbeMatchesNumDatagrama() {
        let xml = """
        <d:Envelope xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
        <d:ProbeMatch>
        <d:Scopes>onvif://www.onvif.org/name/Cam-A</d:Scopes>
        <d:XAddrs>http://192.168.1.11/onvif/device_service</d:XAddrs>
        </d:ProbeMatch>
        <d:ProbeMatch>
        <d:Scopes>onvif://www.onvif.org/name/Cam-B</d:Scopes>
        <d:XAddrs>http://192.168.1.12/onvif/device_service</d:XAddrs>
        </d:ProbeMatch>
        </d:Envelope>
        """
        let devices = OnvifDiscovery.parseProbeMatch(xml)
        XCTAssertEqual(devices.map(\.host), ["192.168.1.11", "192.168.1.12"])
        XCTAssertEqual(devices.map(\.name), ["Cam-A", "Cam-B"])
    }

    func testLixoNaoQuebra() {
        XCTAssertTrue(OnvifDiscovery.parseProbeMatch("não é xml").isEmpty)
        XCTAssertTrue(OnvifDiscovery.parseProbeMatch("").isEmpty)
    }

    func testProbeMessageTemTiposEMessageID() {
        let msg = OnvifDiscovery.probeMessage(messageID: "urn:uuid:abc-123")
        XCTAssertTrue(msg.contains("urn:uuid:abc-123"))
        XCTAssertTrue(msg.contains("dn:NetworkVideoTransmitter"))
        XCTAssertTrue(msg.contains("http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe"))
        // As declarações de namespace precisam ficar na mesma linha (continuação com "\"),
        // sem quebra de linha engolindo o espaço entre os atributos.
        XCTAssertTrue(msg.contains("soap-envelope\" xmlns:w="))
        XCTAssertTrue(msg.contains("xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\""))
    }

    func testNormalizeSerialIgnoraSeparadores() {
        XCTAssertEqual(OnvifDiscovery.normalizeSerial(" amc-0185 3pn:52 "), "AMC01853PN52")
        XCTAssertEqual(OnvifDiscovery.normalizeSerial("U0WI4100062MC"), "U0WI4100062MC")
        XCTAssertEqual(OnvifDiscovery.normalizeSerial(""), "")
    }

    func testFirstMatchingSerialAchaIgnorandoFormato() {
        let devices = [
            DiscoveredDevice(host: "192.168.1.11", serial: "AMC0185-3PN52", xaddr: "http://192.168.1.11/onvif/device_service"),
            DiscoveredDevice(host: "192.168.1.12", serial: "U0WI4100062MC", xaddr: "http://192.168.1.12/onvif/device_service"),
        ]
        XCTAssertEqual(OnvifDiscovery.firstMatchingSerial(devices, serial: "u0wi4100062mc")?.host, "192.168.1.12")
        XCTAssertEqual(OnvifDiscovery.firstMatchingSerial(devices, serial: "amc01853pn52")?.host, "192.168.1.11")
        XCTAssertNil(OnvifDiscovery.firstMatchingSerial(devices, serial: "NAOEXISTE"))
        XCTAssertNil(OnvifDiscovery.firstMatchingSerial(devices, serial: ""))
    }

    func testFirstMatchingSerialIgnoraAparelhoSemSerial() {
        let devices = [DiscoveredDevice(host: "192.168.1.11", xaddr: "http://192.168.1.11/onvif/device_service")]
        XCTAssertNil(OnvifDiscovery.firstMatchingSerial(devices, serial: "QUALQUER"))
    }

    func testScopeValueDesconhecidoFicaNil() {
        let scopes = ["onvif://www.onvif.org/name/X"]
        XCTAssertNil(OnvifDiscovery.scopeValue(scopes, key: "hardware"))
        XCTAssertEqual(OnvifDiscovery.scopeValue(scopes, key: "name"), "X")
    }
}
