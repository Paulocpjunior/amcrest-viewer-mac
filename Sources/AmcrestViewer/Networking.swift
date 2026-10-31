import Foundation
import AmcrestCore

/// Responde ao desafio de autenticação da câmera (Digest ou Basic) com as credenciais dela.
/// Se a senha já foi recusada uma vez, não insiste: deixa o 401 chegar para avisar o usuário.
enum AuthHandling {
    static func handle(
        _ challenge: URLAuthenticationChallenge,
        credential: URLCredential?,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let isLogin = method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodDefault
        if isLogin, challenge.previousFailureCount == 0, let credential {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func credential(for camera: Camera, password: String?) -> URLCredential? {
        guard let password, !password.isEmpty else { return nil }
        // .none: não grava em lugar nenhum; a senha mora só no Keychain do app.
        return URLCredential(user: camera.username, password: password, persistence: .none)
    }

    static func makeConfiguration(requestTimeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return config
    }
}

/// Erros com a ação prática, em português.
enum CameraError: LocalizedError {
    case invalidAddress
    case unauthorized
    case http(Int)
    case unexpectedContent

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Endereço inválido. Edite a câmera e confira o IP ou nome de rede."
        case .unauthorized:
            return "Usuário ou senha recusados pela câmera. Edite a câmera e informe a senha correta."
        case .http(let code) where code == 404:
            return "A câmera não tem este recurso (HTTP 404). Confira o canal ou se o modelo oferece a função."
        case .http(let code):
            return "A câmera respondeu com erro HTTP \(code). Reinicie a câmera ou confira o firmware."
        case .unexpectedContent:
            return "A câmera respondeu algo que não é imagem. Confira se o endereço é mesmo de uma câmera Amcrest/Dahua."
        }
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        if case .unauthorized? = error as? CameraError { return true }
        return false
    }

    /// Traduz falhas de rede em instrução.
    static func friendly(_ error: Error, camera: Camera) -> String {
        if let e = error as? CameraError { return e.errorDescription ?? "\(e)" }
        let target = "\(camera.host):\(camera.httpPort)"
        guard let u = error as? URLError else { return error.localizedDescription }
        switch u.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost:
            return "Sem resposta de \(target). Confira se a câmera está ligada e se o Mac está na mesma rede ou com a VPN (Tailscale) ativa."
        case .cannotFindHost, .dnsLookupFailed:
            return "O nome \(camera.host) não foi encontrado. Confira a grafia ou use o IP."
        case .notConnectedToInternet:
            return "O Mac está sem rede. Conecte ao Wi-Fi ou cabo e tente de novo."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "O certificado HTTPS da câmera não é confiável. Desligue HTTPS na câmera ou use HTTP pela VPN."
        default:
            return "Falha de rede com \(target): \(u.localizedDescription)"
        }
    }
}

private final class TaskAuthDelegate: NSObject, URLSessionTaskDelegate {
    let credential: URLCredential?
    init(credential: URLCredential?) { self.credential = credential }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        AuthHandling.handle(challenge, credential: credential, completionHandler: completionHandler)
    }
}

/// Chamadas pontuais à API HTTP da câmera: snapshot, PTZ, teste de conexão.
struct AmcrestClient {
    let camera: Camera
    let password: String?

    private static let session = URLSession(configuration: AuthHandling.makeConfiguration(requestTimeout: 8))

    func get(_ url: URL?) async throws -> (Data, HTTPURLResponse) {
        guard let url else { throw CameraError.invalidAddress }
        let delegate = TaskAuthDelegate(credential: AuthHandling.credential(for: camera, password: password))
        let (data, response) = try await Self.session.data(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw CameraError.unexpectedContent }
        if http.statusCode == 401 { throw CameraError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CameraError.http(http.statusCode) }
        return (data, http)
    }

    func snapshot() async throws -> Data {
        let (data, http) = try await get(AmcrestEndpoints.snapshot(camera))
        let isJPEG = data.starts(with: [0xFF, 0xD8])
        guard isJPEG || (http.mimeType?.hasPrefix("image/") ?? false) else { throw CameraError.unexpectedContent }
        return data
    }

    func ptz(_ cmd: PTZCommand, start: Bool, speed: Int = 4) async throws {
        _ = try await get(AmcrestEndpoints.ptz(camera, cmd, start: start, speed: speed))
    }

    func gotoPreset(_ preset: Int) async throws {
        _ = try await get(AmcrestEndpoints.gotoPreset(camera, preset: preset))
    }

    /// Resposta típica: `type=IP2M-841B`. Devolve só o modelo.
    func deviceType() async throws -> String {
        let (data, _) = try await get(AmcrestEndpoints.deviceType(camera))
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = text.firstIndex(of: "=") { return String(text[text.index(after: eq)...]) }
        return text
    }
}
