import Foundation

/// Uma câmera (ou um canal de NVR) Amcrest/Dahua.
/// A senha NÃO fica aqui: vai para o Keychain, indexada pelo `id`.
public struct Camera: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var httpPort: Int
    public var rtspPort: Int
    public var channel: Int
    public var username: String
    public var useHTTPS: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        httpPort: Int = 80,
        rtspPort: Int = 554,
        channel: Int = 1,
        username: String = "admin",
        useHTTPS: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.httpPort = httpPort
        self.rtspPort = rtspPort
        self.channel = channel
        self.username = username
        self.useHTTPS = useHTTPS
    }
}

/// Qualidade do fluxo: principal (alta) ou secundário (leve, ideal para grade).
public enum StreamQuality: Int, Codable, Sendable {
    case main = 0
    case sub = 1
}

/// Comandos de PTZ da API HTTP da Amcrest (`/cgi-bin/ptz.cgi`).
public enum PTZCommand: String, CaseIterable, Sendable {
    case up = "Up"
    case down = "Down"
    case left = "Left"
    case right = "Right"
    case leftUp = "LeftUp"
    case rightUp = "RightUp"
    case leftDown = "LeftDown"
    case rightDown = "RightDown"
    case zoomIn = "ZoomTele"
    case zoomOut = "ZoomWide"
}

/// Monta as URLs da API HTTP e do RTSP. Sem rede, sem estado: testável.
public enum AmcrestEndpoints {

    public static func baseURL(_ cam: Camera) -> URL? {
        var c = URLComponents()
        c.scheme = cam.useHTTPS ? "https" : "http"
        c.host = cam.host
        let defaultPort = cam.useHTTPS ? 443 : 80
        if cam.httpPort != defaultPort { c.port = cam.httpPort }
        return c.url
    }

    private static func url(_ cam: Camera, _ path: String, _ query: [(String, String)]) -> URL? {
        guard let base = baseURL(cam),
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.path = path
        c.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url
    }

    /// Quadro único em JPEG.
    public static func snapshot(_ cam: Camera) -> URL? {
        url(cam, "/cgi-bin/snapshot.cgi", [("channel", "\(cam.channel)")])
    }

    /// Fluxo MJPEG (multipart/x-mixed-replace). Muitos modelos só servem MJPEG no subfluxo.
    public static func mjpeg(_ cam: Camera, quality: StreamQuality = .sub) -> URL? {
        url(cam, "/cgi-bin/mjpg/video.cgi", [("channel", "\(cam.channel)"), ("subtype", "\(quality.rawValue)")])
    }

    /// Identificação do aparelho (serve para testar a conexão e a senha).
    public static func deviceType(_ cam: Camera) -> URL? {
        url(cam, "/cgi-bin/magicBox.cgi", [("action", "getDeviceType")])
    }

    /// Início ou fim de um movimento PTZ. `speed` vai de 1 a 8.
    public static func ptz(_ cam: Camera, _ cmd: PTZCommand, start: Bool, speed: Int = 4) -> URL? {
        let s = min(max(speed, 1), 8)
        return url(cam, "/cgi-bin/ptz.cgi", [
            ("action", start ? "start" : "stop"),
            ("channel", "\(cam.channel)"),
            ("code", cmd.rawValue),
            ("arg1", "0"),
            ("arg2", "\(s)"),
            ("arg3", "0"),
        ])
    }

    /// Vai para um preset salvo na câmera.
    public static func gotoPreset(_ cam: Camera, preset: Int) -> URL? {
        url(cam, "/cgi-bin/ptz.cgi", [
            ("action", "start"),
            ("channel", "\(cam.channel)"),
            ("code", "GotoPreset"),
            ("arg1", "0"),
            ("arg2", "\(preset)"),
            ("arg3", "0"),
        ])
    }

    /// URL RTSP. Com `password`, embute as credenciais (para abrir no VLC);
    /// sem `password`, devolve a URL limpa (para exibir).
    public static func rtsp(_ cam: Camera, quality: StreamQuality = .main, password: String? = nil) -> URL? {
        var c = URLComponents()
        c.scheme = "rtsp"
        c.host = cam.host
        c.port = cam.rtspPort
        c.path = "/cam/realmonitor"
        c.queryItems = [
            URLQueryItem(name: "channel", value: "\(cam.channel)"),
            URLQueryItem(name: "subtype", value: "\(quality.rawValue)"),
        ]
        if let password {
            c.user = cam.username
            c.password = password
        }
        return c.url
    }
}
