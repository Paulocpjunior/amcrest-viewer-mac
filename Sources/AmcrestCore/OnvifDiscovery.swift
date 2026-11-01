import Foundation

/// Uma câmera encontrada na rede local pela descoberta ONVIF (WS-Discovery).
/// Sem nuvem: a câmera responde a um broadcast na própria rede.
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public var host: String          // IP (ou host) da câmera na rede local
    public var name: String?         // nome anunciado (scope .../name/)
    public var hardware: String?     // modelo anunciado (scope .../hardware/)
    public var serial: String?       // número de série, se vier no anúncio
    public var useHTTPS: Bool        // esquema anunciado no XAddr (https?)
    public var httpPort: Int         // porta anunciada no XAddr (ou 80/443 por padrão)
    public var xaddr: String         // URL do serviço ONVIF (ex.: http://IP/onvif/device_service)

    public var id: String { host }

    public init(host: String, name: String? = nil, hardware: String? = nil, serial: String? = nil,
                useHTTPS: Bool = false, httpPort: Int = 80, xaddr: String) {
        self.host = host
        self.name = name
        self.hardware = hardware
        self.serial = serial
        self.useHTTPS = useHTTPS
        self.httpPort = httpPort
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

    /// Lê um datagrama de resposta e devolve os aparelhos encontrados.
    /// Tolerante a prefixos de namespace diferentes (d:XAddrs, wsd:XAddrs, etc.).
    /// Cada `<ProbeMatch>` é lido por inteiro, separadamente: assim um aparelho
    /// que omita `Scopes` ou `XAddrs` não rouba o nome/serial de outro no mesmo datagrama.
    public static func parseProbeMatch(_ xml: String) -> [DiscoveredDevice] {
        var out: [DiscoveredDevice] = []
        // Um subárvore por aparelho; se o XML não trouxer <ProbeMatch>, trata tudo como um só.
        var matches = tagValues("ProbeMatch", in: xml)
        if matches.isEmpty { matches = [xml] }
        for match in matches {
            let xaddrs = tagValues("XAddrs", in: match).first ?? ""
            guard let ep = firstHTTPEndpoint(in: xaddrs) else { continue }
            let scopeRaw = tagValues("Scopes", in: match).first ?? ""
            let scopes = scopeRaw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
            out.append(DiscoveredDevice(
                host: ep.host,
                name: scopeValue(scopes, key: "name"),
                hardware: scopeValue(scopes, key: "hardware"),
                serial: scopeValue(scopes, key: "serialNumber") ?? scopeValue(scopes, key: "serial"),
                useHTTPS: ep.useHTTPS,
                httpPort: ep.port,
                xaddr: ep.xaddr
            ))
        }
        return out
    }

    // MARK: - Ajudantes puros

    /// Primeiro endereço http(s) numa lista de XAddrs separada por espaço,
    /// com host, porta e esquema preservados (a câmera pode anunciar https ou porta diferente de 80).
    public static func firstHTTPEndpoint(in xaddrs: String) -> (host: String, port: Int, useHTTPS: Bool, xaddr: String)? {
        for token in xaddrs.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let s = String(token)
            guard let comps = URLComponents(string: s), let h = comps.host, let scheme = comps.scheme,
                  (scheme == "http" || scheme == "https") else { continue }
            let https = scheme == "https"
            return (h, comps.port ?? (https ? 443 : 80), https, s)
        }
        return nil
    }

    /// Normaliza um número de série para comparar: maiúsculas, só letras e dígitos
    /// (ignora espaços, traços e dois-pontos que aparecem de formas diferentes).
    public static func normalizeSerial(_ s: String) -> String {
        String(String(s).uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Primeiro aparelho cujo S/N anunciado bate com o procurado (comparação normalizada).
    public static func firstMatchingSerial(_ devices: [DiscoveredDevice], serial: String) -> DiscoveredDevice? {
        let want = normalizeSerial(serial)
        guard !want.isEmpty else { return nil }
        return devices.first { normalizeSerial($0.serial ?? "") == want }
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
