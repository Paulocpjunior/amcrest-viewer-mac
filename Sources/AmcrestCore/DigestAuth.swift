import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// MD5 em hexadecimal minúsculo (exigido pelo HTTP Digest e pelo login da página da câmera).
public enum MD5Hex {
    public static func of(_ text: String) -> String {
        #if canImport(CryptoKit)
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        fatalError("MD5 requer CryptoKit (macOS)")
        #endif
    }
}

/// Desafio `WWW-Authenticate: Digest ...` da câmera e o cabeçalho `Authorization` de resposta (RFC 2617).
/// O app monta o Digest ele mesmo, em vez de deixar o URLSession negociar: assim cada pedido tem
/// tempo limite próprio e dá para saber em que passo a câmera parou de responder.
public struct DigestChallenge: Equatable, Sendable {
    public var realm: String
    public var nonce: String
    public var qop: String?
    public var opaque: String?
    public var algorithm: String?

    public init(realm: String, nonce: String, qop: String? = nil, opaque: String? = nil, algorithm: String? = nil) {
        self.realm = realm
        self.nonce = nonce
        self.qop = qop
        self.opaque = opaque
        self.algorithm = algorithm
    }

    /// Lê o desafio Digest de um cabeçalho `WWW-Authenticate` (pode vir junto de um desafio Basic).
    public static func parse(_ header: String) -> DigestChallenge? {
        guard let start = header.range(of: "Digest ", options: .caseInsensitive) else { return nil }
        let params = parameters(String(header[start.upperBound...]))
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        return DigestChallenge(realm: realm, nonce: nonce, qop: params["qop"],
                               opaque: params["opaque"], algorithm: params["algorithm"])
    }

    /// `chave="valor", chave=valor` → dicionário (chaves em minúsculas).
    static func parameters(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = text.startIndex
        func skip(_ set: Set<Character>) { while i < text.endIndex, set.contains(text[i]) { i = text.index(after: i) } }
        while i < text.endIndex {
            skip([" ", ",", "\t"])
            let keyStart = i
            while i < text.endIndex, text[i] != "=", text[i] != "," { i = text.index(after: i) }
            let key = text[keyStart..<i].trimmingCharacters(in: .whitespaces).lowercased()
            guard i < text.endIndex, text[i] == "=" else { continue }
            i = text.index(after: i)
            var value = ""
            if i < text.endIndex, text[i] == "\"" {
                i = text.index(after: i)
                while i < text.endIndex, text[i] != "\"" {
                    if text[i] == "\\", text.index(after: i) < text.endIndex { i = text.index(after: i) }
                    value.append(text[i])
                    i = text.index(after: i)
                }
                if i < text.endIndex { i = text.index(after: i) }
            } else {
                let vStart = i
                while i < text.endIndex, text[i] != "," { i = text.index(after: i) }
                value = text[vStart..<i].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// Valor do cabeçalho `Authorization` para `method uri` (uri = caminho + query, como no pedido).
    public func authorization(method: String, uri: String, username: String, password: String,
                              nc: Int, cnonce: String) -> String {
        let ha1 = MD5Hex.of("\(username):\(realm):\(password)")
        let ha2 = MD5Hex.of("\(method):\(uri)")
        let ncText = String(format: "%08x", nc)
        let useQop = qop.flatMap { q in
            q.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("auth") ? "auth" : nil
        }
        let response: String
        if let useQop {
            response = MD5Hex.of("\(ha1):\(nonce):\(ncText):\(cnonce):\(useQop):\(ha2)")
        } else {
            response = MD5Hex.of("\(ha1):\(nonce):\(ha2)")
        }
        var parts = [
            "username=\"\(username)\"",
            "realm=\"\(realm)\"",
            "nonce=\"\(nonce)\"",
            "uri=\"\(uri)\"",
        ]
        if let algorithm { parts.append("algorithm=\(algorithm)") }
        parts.append("response=\"\(response)\"")
        if let opaque { parts.append("opaque=\"\(opaque)\"") }
        if let useQop {
            parts.append("qop=\(useQop)")
            parts.append("nc=\(ncText)")
            parts.append("cnonce=\"\(cnonce)\"")
        }
        return "Digest " + parts.joined(separator: ", ")
    }

    /// Caminho + query do URL, como vai na linha do pedido HTTP.
    public static func requestURI(_ url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path }
        let path = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let q = comps.percentEncodedQuery { return "\(path)?\(q)" }
        return path
    }
}

/// Login da página web da câmera (`/RPC2_Login`, o mesmo que o Safari usa), usado só para
/// diagnosticar: confirma se usuário e senha estão certos ou se a conta está bloqueada.
/// É a API local da própria câmera; não envolve nuvem nem o app oficial.
public enum WebLogin {
    public enum Outcome: Equatable, Sendable {
        case ok
        case wrongPassword
        case locked(String?)
        case other(String)
    }

    public static let lockedCodes: Set<Int> = [268632081]

    /// Corpo do 1º passo (pede o desafio).
    public static func challengeBody(username: String) -> [String: Any] {
        ["method": "global.login", "id": 1,
         "params": ["userName": username, "password": "", "clientType": "Web3.0", "loginType": "Direct"]]
    }

    /// Senha no formato que a página envia (encryption "Default").
    public static func passwordHash(username: String, password: String, realm: String, random: String) -> String {
        let inner = MD5Hex.of("\(username):\(realm):\(password)").uppercased()
        return MD5Hex.of("\(username):\(random):\(inner)").uppercased()
    }

    /// Interpreta a resposta do 2º passo.
    public static func outcome(result: Bool, code: Int?, message: String?) -> Outcome {
        if result { return .ok }
        let msg = message ?? ""
        if let code, lockedCodes.contains(code) { return .locked(msg.isEmpty ? nil : msg) }
        if msg.lowercased().contains("lock") { return .locked(msg) }
        if let code, code == 268632085 || code == 268632071 { return .wrongPassword }
        if msg.lowercased().contains("password") || msg.lowercased().contains("user") { return .wrongPassword }
        return .other(msg.isEmpty ? "código \(code.map(String.init) ?? "?")" : msg)
    }
}
