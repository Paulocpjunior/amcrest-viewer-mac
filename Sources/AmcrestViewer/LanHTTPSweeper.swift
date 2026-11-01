import Foundation
import AmcrestCore

/// Varre a faixa de IP da rede interna (o /24 de cada interface física do Mac) perguntando
/// o S/N pela API HTTP da câmera (`magicBox.cgi?action=getSerialNo`). Acha NVRs e câmeras
/// que não respondem ONVIF. Só rede local: não sai para a internet nem usa nuvem.
enum LanHTTPSweeper {
    /// Pedidos simultâneos. 254 IPs × 1 porta levam poucos segundos.
    static let concurrency = 48

    private static let session: URLSession = {
        let config = AuthHandling.makeConfiguration(requestTimeout: 1.5)
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    /// IPs das interfaces físicas ativas (sem VPN), base da faixa a varrer.
    static func localIPs() -> [String] {
        NetworkScanner.activeIPv4Interfaces().map(\.ip)
    }

    /// Varre a faixa. Com `serial`, para no primeiro aparelho com esse S/N e devolve só ele.
    /// Sem `serial`, devolve todos os aparelhos Amcrest/Dahua que informaram o S/N.
    static func sweep(serial: String?, username: String, password: String?, preferredPort: Int?) async -> [DiscoveredDevice] {
        let hosts = LanSweep.hosts(inSubnetsOf: localIPs())
        let ports = LanSweep.httpPorts(preferred: preferredPort)
        let targets = hosts.flatMap { h in ports.map { (h, $0) } }
        let want = serial.map(OnvifDiscovery.normalizeSerial)

        return await withTaskGroup(of: DiscoveredDevice?.self) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<concurrency {
                guard let target = iterator.next() else { break }
                let (host, port) = target
                group.addTask { await probe(host: host, port: port, username: username, password: password) }
            }
            var found: [DiscoveredDevice] = []
            while let result = await group.next() {
                if let device = result {
                    if let want, !want.isEmpty {
                        if OnvifDiscovery.normalizeSerial(device.serial ?? "") == want {
                            group.cancelAll()
                            return [device]
                        }
                    } else {
                        found.append(device)
                    }
                }
                if let target = iterator.next() {
                    let (host, port) = target
                    group.addTask { await probe(host: host, port: port, username: username, password: password) }
                }
            }
            return found
        }
    }

    /// Pergunta o S/N a um IP. Devolve o aparelho só se ele se identificar com um S/N.
    static func probe(host: String, port: Int, username: String, password: String?) async -> DiscoveredDevice? {
        if Task.isCancelled { return nil }
        let cam = Camera(name: "", host: host, httpPort: port, username: username)
        guard let url = AmcrestEndpoints.magicBox(cam, .serialNumber),
              let result = try? await session.data(from: url),
              let http = result.1 as? HTTPURLResponse else { return nil }

        var sn: String?
        switch http.statusCode {
        case 200:
            let text = String(decoding: result.0, as: UTF8.self)
            if text.lowercased().contains("sn=") { sn = DahuaResponse.singleValue(text, key: "sn") }
        case 401:
            // Amcrest/Dahua: realm="Login to <S/N>" — dá o S/N sem precisar de senha.
            if let header = http.value(forHTTPHeaderField: "WWW-Authenticate") {
                sn = LanSweep.serialFromAuthHeader(header)
            }
            if sn == nil, let password, !password.isEmpty, !Task.isCancelled,
               let authed = try? await AmcrestClient(camera: cam, password: password).get(url) {
                sn = DahuaResponse.singleValue(String(decoding: authed.0, as: UTF8.self), key: "sn")
            }
        default:
            return nil
        }
        guard let sn, !sn.isEmpty else { return nil }
        return DiscoveredDevice(host: host, serial: sn, useHTTPS: false, httpPort: port, xaddr: url.absoluteString)
    }
}
