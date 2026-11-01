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
    /// A câmera respondeu ao primeiro contato (pediu login), mas ficou muda ao receber usuário e senha.
    case loginNoResponse

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
        case .loginNoResponse:
            return "A câmera está na rede e pediu login, mas não respondeu depois de receber usuário e senha. Em Administração → Status, \"Testar todas agora\" confere a senha pelo mesmo login do Safari e diz o motivo."
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
        case .timedOut where camera.host.hasPrefix("192.168.") || camera.host.hasPrefix("10.") || camera.host.hasPrefix("172."):
            return "\(target) não respondeu a tempo. Se a câmera está em outro local, ela só abre na rede dela. Se está nesta rede e ligada, pode ter bloqueado o login por tentativas com senha errada (a Amcrest bloqueia até 30 min): feche o app, confira a senha em http://\(camera.host) no Safari e abra de novo."
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
        let (data, http) = try await CameraHTTP.send(url, camera: camera, password: password, session: Self.session)
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
        let request = try await CameraHTTP.authorizedRequest(url, camera: camera, password: password, session: Self.session)
        let delegate = TaskAuthDelegate(credential: AuthHandling.credential(for: camera, password: password))
        let (tmp, response) = try await Self.session.download(for: request, delegate: delegate)
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

/// Login Digest montado pelo próprio app (em vez da negociação automática do URLSession).
/// 1. Pede o desafio à câmera (resposta 401 rápida, sem senha).
/// 2. Manda o pedido já com `Authorization`. Guarda o desafio para os próximos pedidos (snapshots seguidos).
/// Se a câmera responde ao passo 1 e some no passo 2, o erro diz isso (`loginNoResponse`).
enum CameraHTTP {
    private actor ChallengeCache {
        private var entries: [String: (DigestChallenge, Int)] = [:]
        func next(_ key: String) -> (DigestChallenge, Int)? {
            guard var e = entries[key] else { return nil }
            e.1 += 1
            entries[key] = e
            return e
        }
        func store(_ key: String, _ c: DigestChallenge) -> Int { entries[key] = (c, 1); return 1 }
        func drop(_ key: String) { entries[key] = nil }
    }
    private static let cache = ChallengeCache()
    static let probeSession = URLSession(configuration: AuthHandling.makeConfiguration(requestTimeout: 6))

    private static func key(_ camera: Camera) -> String { "\(camera.username)@\(camera.host):\(camera.httpPort)" }

    private static func cnonce() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func header(_ challenge: DigestChallenge, nc: Int, url: URL, camera: Camera, password: String) -> String {
        challenge.authorization(method: "GET", uri: DigestChallenge.requestURI(url),
                                username: camera.username, password: password, nc: nc, cnonce: cnonce())
    }

    static func basic(_ camera: Camera, _ password: String) -> String {
        "Basic " + Data("\(camera.username):\(password)".utf8).base64EncodedString()
    }

    /// Pedido com o login pronto. Sem senha, vai sem login.
    static func authorizedRequest(_ url: URL, camera: Camera, password: String?,
                                  session: URLSession = probeSession, fresh: Bool = false) async throws -> URLRequest {
        var request = URLRequest(url: url)
        guard let password, !password.isEmpty else { return request }
        if fresh { await cache.drop(key(camera)) }
        if let entry = await cache.next(key(camera)) {
            let (c, nc) = entry
            request.setValue(header(c, nc: nc, url: url, camera: camera, password: password), forHTTPHeaderField: "Authorization")
            return request
        }
        // Desafio novo, pedido leve (modelo do aparelho).
        guard let probe = AmcrestEndpoints.deviceType(camera) else { return request }
        let (_, response) = try await session.data(from: probe)
        guard let http = response as? HTTPURLResponse, http.statusCode == 401,
              let value = http.value(forHTTPHeaderField: "WWW-Authenticate") else { return request }
        if let c = DigestChallenge.parse(value) {
            let nc = await cache.store(key(camera), c)
            request.setValue(header(c, nc: nc, url: url, camera: camera, password: password), forHTTPHeaderField: "Authorization")
        } else if value.lowercased().hasPrefix("basic") {
            request.setValue(basic(camera, password), forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// GET com login. Devolve a resposta como veio (inclusive 401); quem chama decide o erro.
    static func send(_ url: URL, camera: Camera, password: String?, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        guard let password, !password.isEmpty else { return try await plain(URLRequest(url: url), session) }
        let k = key(camera)

        // 1º contato: sem login, para receber o desafio (ou a resposta, se a câmera não pedir login).
        var challenge: DigestChallenge?
        var nc = 1
        if let entry = await cache.next(k) {
            challenge = entry.0; nc = entry.1
        } else {
            let (data, http) = try await plain(URLRequest(url: url), session)
            guard http.statusCode == 401 else { return (data, http) }
            let value = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            if let c = DigestChallenge.parse(value) {
                challenge = c; nc = await cache.store(k, c)
            } else if value.lowercased().hasPrefix("basic") {
                var r = URLRequest(url: url)
                r.setValue(basic(camera, password), forHTTPHeaderField: "Authorization")
                return try await authed(r, session)
            } else {
                return (data, http)
            }
        }

        guard let c = challenge else { throw CameraError.unexpectedContent }
        var request = URLRequest(url: url)
        request.setValue(header(c, nc: nc, url: url, camera: camera, password: password), forHTTPHeaderField: "Authorization")
        let (data, http) = try await authed(request, session)
        guard http.statusCode == 401 else { return (data, http) }

        // Desafio vencido (nonce novo) ou senha errada: tenta uma vez com o desafio que veio agora.
        await cache.drop(k)
        guard let value = http.value(forHTTPHeaderField: "WWW-Authenticate"),
              let fresh = DigestChallenge.parse(value) else { return (data, http) }
        let n2 = await cache.store(k, fresh)
        var retry = URLRequest(url: url)
        retry.setValue(header(fresh, nc: n2, url: url, camera: camera, password: password), forHTTPHeaderField: "Authorization")
        let result = try await authed(retry, session)
        if result.1.statusCode == 401 { await cache.drop(k) }
        return result
    }

    private static func plain(_ request: URLRequest, _ session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CameraError.unexpectedContent }
        return (data, http)
    }

    /// Pedido já com login. Se a câmera ficar muda aqui, o problema é o login (ela respondeu antes).
    private static func authed(_ request: URLRequest, _ session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await plain(request, session)
        } catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost {
            throw CameraError.loginNoResponse
        }
    }
}

/// Confere usuário e senha pelo login da página da câmera (`/RPC2_Login`, o mesmo do Safari).
/// Só para diagnóstico: não abre vídeo, encerra a sessão logo em seguida.
enum WebLoginCheck {
    static func run(camera: Camera, password: String?) async -> WebLogin.Outcome? {
        guard let password, !password.isEmpty,
              let base = URL(string: "\(camera.useHTTPS ? "https" : "http")://\(camera.host):\(camera.httpPort)") else { return nil }
        let config = AuthHandling.makeConfiguration(requestTimeout: 6)
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
            var r = URLRequest(url: base.appendingPathComponent(path))
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let result = try? await session.data(for: r) else { return nil }
            return (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
        }

        guard let first = await post("RPC2_Login", WebLogin.challengeBody(username: camera.username)),
              let params = first["params"] as? [String: Any],
              let realm = params["realm"] as? String, let random = params["random"] as? String else {
            if let first, let err = first["error"] as? [String: Any] {
                return WebLogin.outcome(result: false, code: err["code"] as? Int, message: err["message"] as? String)
            }
            return nil
        }
        let session1 = first["session"]
        let hash = WebLogin.passwordHash(username: camera.username, password: password, realm: realm, random: random)
        var body: [String: Any] = [
            "method": "global.login", "id": 2,
            "params": ["userName": camera.username, "password": hash, "clientType": "Web3.0",
                       "loginType": "Direct", "authorityType": params["encryption"] as? String ?? "Default"],
        ]
        if let session1 { body["session"] = session1 }
        guard let second = await post("RPC2_Login", body) else { return .other("sem resposta ao login") }
        let ok = second["result"] as? Bool ?? false
        if ok, let s = second["session"] {
            _ = await post("RPC2", ["method": "global.logout", "params": NSNull(), "id": 3, "session": s])
        }
        let err = second["error"] as? [String: Any]
        return WebLogin.outcome(result: ok, code: err?["code"] as? Int, message: err?["message"] as? String)
    }
}

/// Quando o login pela API falha, confere a senha pelo login da página (o do Safari) e explica o motivo.
enum LoginDiagnosis {
    static func explain(_ error: Error, camera: Camera, password: String?) async -> String {
        let base = CameraError.friendly(error, camera: camera)
        let loginProblem: Bool
        switch error as? CameraError {
        case .loginNoResponse?, .unauthorized?: loginProblem = true
        default: loginProblem = false
        }
        guard loginProblem else { return base }
        guard let outcome = await WebLoginCheck.run(camera: camera, password: password) else { return base }
        switch outcome {
        case .ok:
            return "Usuário e senha estão certos (o login da página da câmera aceitou), mas a câmera não libera a API de imagem para este usuário. Na página http://\(camera.host) confira Configuração → Sistema → Segurança/Serviços: deixe \"Autenticação\" em Digest/Basic (não só \"Segura\") e o CGI habilitado."
        case .wrongPassword:
            return "A câmera recusou a senha do usuário \(camera.username). Edite a câmera em Administração e digite a mesma senha que você usa no Safari."
        case .locked(let msg):
            return "A câmera bloqueou o usuário \(camera.username) por excesso de tentativas\(msg.map { " (\($0))" } ?? ""). Espere 30 minutos sem abrir o app, ou reinicie a câmera, e tente de novo."
        case .other(let msg):
            return base + " (login da página: \(msg))"
        }
    }
}
