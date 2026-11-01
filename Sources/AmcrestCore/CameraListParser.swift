import Foundation

/// Lê a lista de câmeras de um .txt.
///
/// Uma câmera por linha. Linhas vazias e linhas que começam com `#` são ignoradas.
/// Formatos aceitos (separados por espaço, tab, vírgula, ponto e vírgula, `=` ou ` - `):
///
///     192.168.1.10
///     192.168.1.10:8080
///     Garagem 192.168.1.10
///     Garagem, 192.168.1.10, admin
///     Portão = 192.168.1.11:80 canal 2
///     http://192.168.1.12
///     rtsp://admin:senha@192.168.1.13:554/cam/realmonitor?channel=1&subtype=0
///     cam-quintal.local
///     Portão 192.168.1.11 sn AMC01853PN52UCB543
///
/// O que não for reconhecido NÃO é adivinhado: a linha volta em `rejected`,
/// com o motivo, para o usuário corrigir o arquivo.
public enum CameraListParser {

    public struct ParsedCamera: Equatable, Sendable {
        public var camera: Camera
        /// Senha encontrada no próprio arquivo (dentro de uma URL), se houver.
        /// Deve ir para o Keychain e nunca ser gravada em outro lugar.
        public var password: String?
        public var lineNumber: Int
    }

    public struct Rejected: Equatable, Sendable {
        public var lineNumber: Int
        public var line: String
        public var reason: String
    }

    public struct Result: Equatable, Sendable {
        public var cameras: [ParsedCamera] = []
        public var rejected: [Rejected] = []
    }

    public static func parse(_ text: String) -> Result {
        var result = Result()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        for (idx, raw) in lines.enumerated() {
            let n = idx + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }

            switch parseLine(line) {
            case .success(var parsed):
                parsed.lineNumber = n
                if parsed.camera.name.isEmpty {
                    parsed.camera.name = defaultName(parsed.camera)
                }
                result.cameras.append(parsed)
            case .failure(let reason):
                result.rejected.append(Rejected(lineNumber: n, line: line, reason: reason.message))
            }
        }
        return result
    }

    struct Reason: Error { let message: String }

    static func parseLine(_ line: String) -> Swift.Result<ParsedCamera, Reason> {
        // URLs primeiro: podem conter caracteres que seriam tratados como separador.
        let tokens = tokenize(line)
        var nameParts: [String] = []
        var camera: Camera?
        var password: String?
        var explicitUser: String?
        var explicitChannel: Int?
        var serial: String?

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            let lower = t.lowercased()

            if lower.hasPrefix("rtsp://") || lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                guard camera == nil else { return .failure(Reason(message: "mais de um endereço na mesma linha; use uma câmera por linha")) }
                guard let (cam, pass) = fromURL(t) else {
                    return .failure(Reason(message: "URL inválida: \(t)"))
                }
                camera = cam
                password = pass
            } else if ["canal", "channel", "ch"].contains(lower), i + 1 < tokens.count, let ch = Int(tokens[i + 1]), ch > 0 {
                explicitChannel = ch
                i += 1
            } else if let ch = channelSuffix(lower) {
                explicitChannel = ch
            } else if let sn = serialPrefix(t) {
                serial = sn
            } else if serialKeywords.contains(lower), i + 1 < tokens.count {
                serial = tokens[i + 1]
                i += 1
            } else if ["usuario", "usuário", "user", "login"].contains(lower), i + 1 < tokens.count {
                explicitUser = tokens[i + 1]
                i += 1
            } else if let hp = hostPort(t) {
                guard camera == nil else { return .failure(Reason(message: "mais de um endereço na mesma linha; use uma câmera por linha")) }
                var cam = Camera(name: "", host: hp.host)
                if let p = hp.port { cam.httpPort = p }
                camera = cam
            } else if camera != nil, explicitUser == nil, isLikelyUser(t) {
                // "Nome, IP, admin": login conhecido depois do endereço = usuário.
                explicitUser = t
            } else {
                nameParts.append(t)
            }
            i += 1
        }

        guard var cam = camera else {
            if let serial {
                return .failure(Reason(message: "só o S/N \(serial), sem IP: a conexão pelo S/N ainda não é suportada; informe também o IP local da câmera"))
            }
            return .failure(Reason(message: "nenhum IP, nome de rede (ex.: cam.local) ou URL encontrado"))
        }
        if let explicitChannel { cam.channel = explicitChannel }
        if let explicitUser { cam.username = explicitUser }
        if let serial { cam.serialNumber = serial }
        cam.name = nameParts.joined(separator: " ")
        return .success(ParsedCamera(camera: cam, password: password, lineNumber: 0))
    }

    // MARK: - Auxiliares

    static func tokenize(_ line: String) -> [String] {
        var out: [String] = []
        for piece in line.components(separatedBy: .whitespaces) where !piece.isEmpty {
            let l = piece.lowercased()
            if l.hasPrefix("rtsp://") || l.hasPrefix("http://") || l.hasPrefix("https://") {
                out.append(piece.trimmingCharacters(in: CharacterSet(charactersIn: ",;")))
                continue
            }
            if piece == "-" || piece == "=" { continue }
            for sub in piece.components(separatedBy: CharacterSet(charactersIn: ",;=")) {
                let s = sub.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
            }
        }
        return out
    }

    static func fromURL(_ s: String) -> (Camera, String?)? {
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              let host = c.host, !host.isEmpty else { return nil }
        var cam = Camera(name: "", host: host)
        switch scheme {
        case "rtsp":
            if let p = c.port { cam.rtspPort = p }
        case "https":
            cam.useHTTPS = true
            cam.httpPort = c.port ?? 443
        default:
            if let p = c.port { cam.httpPort = p }
        }
        if let ch = c.queryItems?.first(where: { $0.name.lowercased() == "channel" })?.value.flatMap(Int.init), ch > 0 {
            cam.channel = ch
        }
        if let u = c.percentEncodedUser, !u.isEmpty { cam.username = u.removingPercentEncoding ?? u }
        let pass = c.percentEncodedPassword.map { $0.removingPercentEncoding ?? $0 }
        return (cam, (pass?.isEmpty ?? true) ? nil : pass)
    }

    /// Aceita IPv4 (com porta opcional) e nomes de rede com ponto (ex.: cam.local, minhacasa.ddns.net).
    public static func hostPort(_ s: String) -> (host: String, port: Int?)? {
        var host = s
        var port: Int?
        if let colon = s.lastIndex(of: ":"), s.filter({ $0 == ":" }).count == 1 {
            host = String(s[..<colon])
            guard let p = Int(s[s.index(after: colon)...]), (1...65535).contains(p) else { return nil }
            port = p
        }
        if isIPv4(host) { return (host, port) }
        if isHostname(host) { return (host, port) }
        return nil
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let v = Int(p) else { return false }
            return (0...255).contains(v)
        }
    }

    static func isHostname(_ s: String) -> Bool {
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, s.count <= 253 else { return false }
        // Só números com pontos = IPv4 malformado, não nome de rede.
        if s.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let tld = labels.last!
        guard tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-")
                && l.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
        }
    }

    static func channelSuffix(_ lower: String) -> Int? {
        for prefix in ["canal", "channel", "ch"] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count)
            if let n = Int(rest), n > 0 { return n }
        }
        return nil
    }

    static let serialKeywords: Set<String> = ["sn", "s/n", "sn:", "s/n:", "serial", "serial:"]

    /// "sn:AMC0185..." ou "s/n:AMC0185..." num token só.
    static func serialPrefix(_ token: String) -> String? {
        for prefix in ["s/n:", "sn:", "serial:"] where token.lowercased().hasPrefix(prefix) {
            let rest = token.dropFirst(prefix.count)
            if !rest.isEmpty { return String(rest) }
        }
        return nil
    }

    static func isLikelyUser(_ s: String) -> Bool {
        ["admin", "administrator", "root", "user", "viewer"].contains(s.lowercased())
    }

    static func defaultName(_ cam: Camera) -> String {
        cam.channel > 1 ? "\(cam.host) · canal \(cam.channel)" : cam.host
    }
}
