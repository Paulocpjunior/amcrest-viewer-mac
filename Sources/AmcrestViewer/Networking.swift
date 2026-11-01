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
            return "Sem resposta de \(target). Confira se a câmera está ligada e se o Mac está na mesma rede dela. Com o S/N no cadastro, o app procura o IP novo sozinho."
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

    // MARK: Presets

    func presets() async throws -> [PTZPreset] {
        let (data, _) = try await get(AmcrestEndpoints.getPresets(camera))
        return DahuaResponse.presets(String(decoding: data, as: UTF8.self))
    }

    func setPreset(_ preset: Int) async throws {
        _ = try await get(AmcrestEndpoints.setPreset(camera, preset: preset))
    }

    // MARK: Gravações do microSD

    /// Lista os vídeos gravados entre `from` e `to`, em ordem de horário.
    /// Para no máximo `limit` arquivos, para não travar com cartões cheios.
    func recordings(from: Date, to: Date, limit: Int = 2000) async throws -> [RecordingFile] {
        let (created, _) = try await get(AmcrestEndpoints.mediaFindCreate(camera))
        guard let object = DahuaResponse.findObject(String(decoding: created, as: UTF8.self)) else {
            throw CameraError.unexpectedContent
        }
        defer {
            // Libera o objeto na câmera mesmo se algo falhar no meio.
            let cam = camera, pwd = password
            Task {
                let c = AmcrestClient(camera: cam, password: pwd)
                _ = try? await c.get(AmcrestEndpoints.mediaFindClose(cam, object: object))
                _ = try? await c.get(AmcrestEndpoints.mediaFindDestroy(cam, object: object))
            }
        }
        do {
            _ = try await get(AmcrestEndpoints.mediaFindStart(camera, object: object, from: from, to: to))
        } catch CameraError.http(400) {
            // A câmera responde 400 quando não há nada gravado no período (ou não há cartão).
            return []
        }
        var all: [RecordingFile] = []
        let page = 100
        while all.count < limit {
            let (data, _) = try await get(AmcrestEndpoints.mediaFindNext(camera, object: object, count: page))
            let (found, files) = DahuaResponse.recordings(String(decoding: data, as: UTF8.self))
            all += files
            if found < page || files.isEmpty { break }
        }
        return all.sorted { $0.start < $1.start }
    }

    /// Baixa um arquivo gravado para `destination` (substitui se já existir).
    func download(_ file: RecordingFile, to destination: URL) async throws {
        guard let url = AmcrestEndpoints.loadFile(camera, path: file.filePath) else { throw CameraError.invalidAddress }
        let delegate = TaskAuthDelegate(credential: AuthHandling.credential(for: camera, password: password))
        let (tmp, response) = try await Self.session.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw CameraError.unexpectedContent }
        if http.statusCode == 401 { throw CameraError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CameraError.http(http.statusCode) }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
    }

    /// Ficha do aparelho (modelo, firmware, S/N, hardware), para a Administração.
    /// Só falha se nem o modelo responder; os outros campos são opcionais (nem todo firmware tem todos).
    func deviceInfo() async throws -> DeviceInfo {
        var info = DeviceInfo()
        info.model = try await deviceType()
        if let text = await magicText(.softwareVersion), let v = DahuaResponse.softwareVersion(text) {
            info.firmware = v.version
            info.firmwareBuild = v.build
        }
        if let text = await magicText(.serialNumber) {
            info.serial = DahuaResponse.singleValue(text, key: "sn")
        }
        if let text = await magicText(.hardwareVersion) {
            info.hardware = DahuaResponse.singleValue(text, key: "version")
        }
        return info
    }

    /// Resposta texto de uma ação do magicBox, ou nil se a câmera não tiver a ação.
    private func magicText(_ action: MagicBoxAction) async -> String? {
        guard let result = try? await get(AmcrestEndpoints.magicBox(camera, action)) else { return nil }
        return String(decoding: result.0, as: UTF8.self)
    }

    /// Resposta típica: `type=IP2M-841B`. Devolve só o modelo.
    func deviceType() async throws -> String {
        let (data, _) = try await get(AmcrestEndpoints.deviceType(camera))
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = text.firstIndex(of: "=") { return String(text[text.index(after: eq)...]) }
        return text
    }
}
