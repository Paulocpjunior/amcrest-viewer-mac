import Foundation

/// Ficha do aparelho, lida da própria câmera pela API HTTP (`magicBox.cgi`).
/// Usada na Administração (aba Hardware). Campos que a câmera não informar ficam nil.
public struct DeviceInfo: Equatable, Sendable {
    public var model: String?
    public var firmware: String?
    public var firmwareBuild: String?
    public var serial: String?
    public var hardware: String?

    public init(model: String? = nil, firmware: String? = nil, firmwareBuild: String? = nil,
                serial: String? = nil, hardware: String? = nil) {
        self.model = model
        self.firmware = firmware
        self.firmwareBuild = firmwareBuild
        self.serial = serial
        self.hardware = hardware
    }
}

/// Ações de leitura do `magicBox.cgi` usadas na ficha do aparelho.
public enum MagicBoxAction: String, CaseIterable, Sendable {
    case deviceType = "getDeviceType"
    case softwareVersion = "getSoftwareVersion"
    case serialNumber = "getSerialNo"
    case hardwareVersion = "getHardwareVersion"
}

extension AmcrestEndpoints {
    /// `/cgi-bin/magicBox.cgi?action=<ação>` (só leitura).
    public static func magicBox(_ cam: Camera, _ action: MagicBoxAction) -> URL? {
        guard let base = baseURL(cam),
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.path = "/cgi-bin/magicBox.cgi"
        c.queryItems = [URLQueryItem(name: "action", value: action.rawValue)]
        return c.url
    }
}

extension DahuaResponse {
    /// Valor de uma resposta de uma linha só (`type=IP2M-841B`, `sn=AMC0...`).
    /// Se a câmera devolver só o valor, sem `chave=`, usa o texto inteiro.
    public static func singleValue(_ text: String, key: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let kv = keyValues(trimmed)
        if let v = kv[key] { return v.isEmpty ? nil : v }
        if trimmed.contains("=") { return kv.values.first.flatMap { $0.isEmpty ? nil : $0 } }
        return trimmed
    }

    /// `version=2.420.AC00.18.R,build:2018-09-13` → ("2.420.AC00.18.R", "2018-09-13").
    public static func softwareVersion(_ text: String) -> (version: String, build: String?)? {
        guard let raw = singleValue(text, key: "version") else { return nil }
        let parts = raw.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let version = parts.first, !version.isEmpty else { return nil }
        var build: String?
        if parts.count > 1 {
            let b = parts[1]
            if let colon = b.firstIndex(of: ":") {
                build = String(b[b.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                build = b
            }
            if build?.isEmpty == true { build = nil }
        }
        return (version, build)
    }
}

/// Regras da tela de Administração que não dependem de interface (testáveis).
public enum CameraAdmin {
    /// Filtra por nome, endereço ou S/N, sem diferenciar maiúsculas e acentos.
    public static func filter(_ cameras: [Camera], query: String) -> [Camera] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return cameras }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return cameras.filter { cam in
            cam.name.range(of: q, options: opts) != nil
                || cam.host.range(of: q, options: opts) != nil
                || (cam.serialNumber?.range(of: q, options: opts) != nil)
        }
    }

    /// Como a câmera foi cadastrada, para mostrar na lista.
    public static func connectionLabel(_ cam: Camera) -> String {
        var label = cam.host.isEmpty ? "sem endereço" : cam.host
        let defaultPort = cam.useHTTPS ? 443 : 80
        if !cam.host.isEmpty && cam.httpPort != defaultPort { label += ":\(cam.httpPort)" }
        if cam.channel != 1 { label += " · canal \(cam.channel)" }
        return label
    }
}
