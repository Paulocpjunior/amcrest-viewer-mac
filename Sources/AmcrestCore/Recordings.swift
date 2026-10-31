import Foundation

/// Um arquivo gravado no cartão microSD (ou HD do NVR) da câmera.
public struct RecordingFile: Identifiable, Hashable, Sendable {
    public var id: String { filePath }
    public var channel: Int
    public var start: Date
    public var end: Date
    /// `dav` (vídeo) ou `jpg` (foto).
    public var type: String
    /// Caminho dentro da câmera, ex.: `/mnt/sd/2024-01-05/001/dav/09/09.30.37-09.30.47[R][0@0][0].dav`.
    public var filePath: String
    /// Tamanho em bytes, quando a câmera informa.
    public var length: Int?
    /// Eventos que dispararam a gravação, ex.: `VideoMotion`, `AlarmLocal`.
    public var events: [String]
    /// Marcas da câmera, ex.: `Timing` (contínua), `Event`, `Manual`.
    public var flags: [String]

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(channel: Int, start: Date, end: Date, type: String, filePath: String,
                length: Int? = nil, events: [String] = [], flags: [String] = []) {
        self.channel = channel
        self.start = start
        self.end = end
        self.type = type
        self.filePath = filePath
        self.length = length
        self.events = events
        self.flags = flags
    }
}

/// Um preset de PTZ salvo na câmera.
public struct PTZPreset: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var name: String

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

/// Lê as respostas texto da API HTTP Dahua/Amcrest (`chave=valor`, uma por linha).
public enum DahuaResponse {

    /// Linhas `chave=valor`. Linhas sem `=` são ignoradas; a última ocorrência vence.
    public static func keyValues(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// Agrupa chaves `prefixo[N].Campo` por N. Ex.: `items[0].StartTime` → grupo 0, campo `StartTime`.
    /// Campos com índice próprio (`Events[1]`) ficam com o nome completo.
    public static func groups(_ kv: [String: String], prefix: String) -> [Int: [String: String]] {
        var out: [Int: [String: String]] = [:]
        let head = prefix + "["
        for (key, value) in kv where key.hasPrefix(head) {
            let rest = key.dropFirst(head.count)
            guard let close = rest.firstIndex(of: "]"),
                  let n = Int(rest[..<close]) else { continue }
            var field = rest[rest.index(after: close)...]
            if field.hasPrefix(".") { field = field.dropFirst() }
            out[n, default: [:]][String(field)] = value
        }
        return out
    }

    /// Valores de um campo em lista (`Events[0]`, `Events[1]`...), em ordem.
    static func list(_ fields: [String: String], _ name: String) -> [String] {
        let head = name + "["
        return fields.compactMap { key, value -> (Int, String)? in
            guard key.hasPrefix(head), key.hasSuffix("]"),
                  let n = Int(key.dropFirst(head.count).dropLast()) else { return nil }
            return (n, value)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    /// Resposta de `mediaFileFind.cgi?action=factory.create`: `result=08137`.
    public static func findObject(_ text: String) -> String? {
        guard let v = keyValues(text)["result"], !v.isEmpty else { return nil }
        return v
    }

    /// Resposta de `findNextFile`. Devolve quantos a câmera disse ter achado e os arquivos lidos.
    /// Itens sem caminho ou com data ilegível são descartados (não dá para baixar nem tocar).
    public static func recordings(_ text: String, timeZone: TimeZone = .current) -> (found: Int, files: [RecordingFile]) {
        let kv = keyValues(text)
        let found = Int(kv["found"] ?? "") ?? 0
        let fmt = cameraDateFormatter(timeZone: timeZone)
        let files = groups(kv, prefix: "items")
            .sorted { $0.key < $1.key }
            .compactMap { _, f -> RecordingFile? in
                guard let path = f["FilePath"], !path.isEmpty,
                      let s = f["StartTime"].flatMap(fmt.date(from:)),
                      let e = f["EndTime"].flatMap(fmt.date(from:)) else { return nil }
                return RecordingFile(
                    channel: Int(f["Channel"] ?? "") ?? 1,
                    start: s, end: e,
                    type: f["Type"] ?? "dav",
                    filePath: path,
                    length: Int(f["Length"] ?? ""),
                    events: list(f, "Events"),
                    flags: list(f, "Flags"))
            }
        return (found, files)
    }

    /// Resposta de `ptz.cgi?action=getPresets`: `presets[0].Index=1`, `presets[0].Name=Portão`.
    public static func presets(_ text: String) -> [PTZPreset] {
        groups(keyValues(text), prefix: "presets")
            .compactMap { _, f -> PTZPreset? in
                guard let i = Int(f["Index"] ?? "") else { return nil }
                let name = f["Name"].map { $0.isEmpty ? "Preset \(i)" : $0 } ?? "Preset \(i)"
                return PTZPreset(index: i, name: name)
            }
            .sorted { $0.index < $1.index }
    }

    /// Formato de data da API: `2024-01-05 09:30:37`, no fuso da câmera.
    public static func cameraDateFormatter(timeZone: TimeZone = .current) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-M-d H:m:s"
        return f
    }
}

extension AmcrestEndpoints {

    private static func api(_ cam: Camera, _ path: String, _ query: [(String, String)]) -> URL? {
        guard let base = baseURL(cam),
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.path = path
        c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url
    }

    private static func cameraTime(_ d: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    // MARK: Busca de gravações (mediaFileFind.cgi)

    /// Passo 1: cria o objeto de busca. Resposta `result=<id>`.
    public static func mediaFindCreate(_ cam: Camera) -> URL? {
        api(cam, "/cgi-bin/mediaFileFind.cgi", [("action", "factory.create")])
    }

    /// Passo 2: define o período e o canal. Só vídeo (`dav`).
    public static func mediaFindStart(_ cam: Camera, object: String, from: Date, to: Date,
                                      timeZone: TimeZone = .current) -> URL? {
        api(cam, "/cgi-bin/mediaFileFind.cgi", [
            ("action", "findFile"),
            ("object", object),
            ("condition.Channel", "\(cam.channel)"),
            ("condition.StartTime", cameraTime(from, timeZone: timeZone)),
            ("condition.EndTime", cameraTime(to, timeZone: timeZone)),
            ("condition.Types[0]", "dav"),
        ])
    }

    /// Passo 3 (repetir): próximos `count` arquivos.
    public static func mediaFindNext(_ cam: Camera, object: String, count: Int = 100) -> URL? {
        api(cam, "/cgi-bin/mediaFileFind.cgi", [("action", "findNextFile"), ("object", object), ("count", "\(count)")])
    }

    /// Passo 4: encerra a busca e libera o objeto na câmera.
    public static func mediaFindClose(_ cam: Camera, object: String) -> URL? {
        api(cam, "/cgi-bin/mediaFileFind.cgi", [("action", "close"), ("object", object)])
    }

    public static func mediaFindDestroy(_ cam: Camera, object: String) -> URL? {
        api(cam, "/cgi-bin/mediaFileFind.cgi", [("action", "destroy"), ("object", object)])
    }

    /// Download do arquivo gravado: `/cgi-bin/RPC_Loadfile<FilePath>`.
    public static func loadFile(_ cam: Camera, path: String) -> URL? {
        guard let base = baseURL(cam),
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let p = path.hasPrefix("/") ? path : "/" + path
        c.path = "/cgi-bin/RPC_Loadfile" + p
        return c.url
    }

    /// RTSP de reprodução de um trecho gravado (abre no VLC).
    public static func rtspPlayback(_ cam: Camera, from: Date, to: Date, password: String? = nil,
                                    timeZone: TimeZone = .current) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy_MM_dd_HH_mm_ss"
        var c = URLComponents()
        c.scheme = "rtsp"
        c.host = cam.host
        c.port = cam.rtspPort
        c.path = "/cam/playback"
        c.queryItems = [
            URLQueryItem(name: "channel", value: "\(cam.channel)"),
            URLQueryItem(name: "starttime", value: f.string(from: from)),
            URLQueryItem(name: "endtime", value: f.string(from: to)),
        ]
        if let password {
            c.user = cam.username
            c.password = password
        }
        return c.url
    }

    // MARK: Presets de PTZ

    public static func getPresets(_ cam: Camera) -> URL? {
        api(cam, "/cgi-bin/ptz.cgi", [("action", "getPresets"), ("channel", "\(cam.channel)")])
    }

    /// Grava a posição atual no preset `preset` (sobrescreve o que houver).
    public static func setPreset(_ cam: Camera, preset: Int) -> URL? {
        api(cam, "/cgi-bin/ptz.cgi", [
            ("action", "start"),
            ("channel", "\(cam.channel)"),
            ("code", "SetPreset"),
            ("arg1", "0"),
            ("arg2", "\(preset)"),
            ("arg3", "0"),
        ])
    }
}
