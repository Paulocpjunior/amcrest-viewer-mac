import Foundation

/// Uma câmera encontrada na rede local pela descoberta ONVIF (WS-Discovery).
/// Sem nuvem: a câmera responde a um broadcast na própria rede.
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public var host: String          // IP (ou host) da câmera na rede local
    public var name: String?         // nome anunciado (scope .../name/)
    public var hardware: String?     // modelo anunciado (scope .../hardware/)
    public var serial: String?       // número de série, se vier no anúncio
    public var xaddr: String         // URL do serviço ONVIF (ex.: http://IP/onvif/device_service)

    public var id: String { host }

    public init(host: String, name: String? = nil, hardware: String? = nil, serial: String? = nil, xaddr: String) {
        self.host = host
        self.name = name
        self.hardware = hardware
        self.serial = serial
        self.xaddr = xaddr
    }

    /// Rótulo amigável pra lista: nome, senão modelo, senão o IP.
    public var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let h = hardware, !h.isEmpty { return h }
        return host
    }
}

/// Descoberta de câmeras na rede local pelo padrão aberto ONVIF (WS-Discovery).
/// Aqui mora só a lógica pura (montar o Probe e ler as respostas), testável sem rede.
public enum OnvifDiscovery {
    public static let multicastHost = "239.255.255.250"
    public static let multicastPort: UInt16 = 3702

    /// Mensagem SOAP de Probe do WS-Discovery. `messageID` deve ser único por envio
    /// (ex.: "urn:uuid:<UUID>").
    public static func probeMessage(messageID: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"\
         xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"\
         xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"\
         xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
        <e:Header>
        <w:MessageID>\(messageID)</w:MessageID>
        <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
        <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
        </e:Header>
        <e:Body>
        <d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe>
        </e:Body>
        </e:Envelope>
        """
    }

    /// Lê um datagrama de resposta (ProbeMatch) e devolve os aparelhos encontrados.
    /// Tolerante a prefixos de namespace diferentes (d:XAddrs, wsd:XAddrs, etc.).
    public static func parseProbeMatch(_ xml: String) -> [DiscoveredDevice] {
        var out: [DiscoveredDevice] = []
        let xaddrsList = tagValues("XAddrs", in: xml)
        let scopesList = tagValues("Scopes", in: xml)
        // Normalmente um ProbeMatch por aparelho; casamos por índice, com folga.
        let count = max(xaddrsList.count, 1)
        for i in 0..<count {
            let xaddrs = i < xaddrsList.count ? xaddrsList[i] : ""
            guard let (host, xaddr) = firstHTTPHost(in: xaddrs) else { continue }
            let scopes = i < scopesList.count ? scopesList[i].split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init) : []
            out.append(DiscoveredDevice(
                host: host,
                name: scopeValue(scopes, key: "name"),
                hardware: scopeValue(scopes, key: "hardware"),
                serial: scopeValue(scopes, key: "serialNumber") ?? scopeValue(scopes, key: "serial"),
                xaddr: xaddr
            ))
        }
        return out
    }

    // MARK: - Ajudantes puros

    /// Primeiro host http(s) numa lista de XAddrs separada por espaço.
    public static func firstHTTPHost(in xaddrs: String) -> (host: String, xaddr: String)? {
        for token in xaddrs.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let s = String(token)
            guard let comps = URLComponents(string: s), let h = comps.host,
                  (comps.scheme == "http" || comps.scheme == "https") else { continue }
            return (h, s)
        }
        return nil
    }

    /// Valor de um scope ONVIF "onvif://www.onvif.org/<key>/<valor>" (valor vem percent-encoded).
    public static func scopeValue(_ scopes: [String], key: String) -> String? {
        let needle = "/\(key)/"
        for scope in scopes {
            guard let r = scope.range(of: needle) else { continue }
            let raw = String(scope[r.upperBound...])
            let value = raw.removingPercentEncoding ?? raw
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Conteúdo de todas as tags com o nome local dado, ignorando o prefixo de namespace.
    static func tagValues(_ localName: String, in xml: String) -> [String] {
        let pattern = "<(?:[A-Za-z0-9_.-]+:)?\(localName)\\b[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?\(localName)>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
