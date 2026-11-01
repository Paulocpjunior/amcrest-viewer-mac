import Foundation

/// Uma versão do app: número, data e o que mudou (em português).
public struct Release: Identifiable, Hashable, Sendable {
    public let version: String
    public let date: String          // AAAA-MM-DD
    public let title: String
    public let changes: [String]

    public var id: String { version }

    public init(version: String, date: String, title: String, changes: [String]) {
        self.version = version
        self.date = date
        self.title = title
        self.changes = changes
    }

    /// Data no formato do Brasil (01/11/2026). Se a data for inválida, devolve como veio.
    public var displayDate: String {
        let p = date.split(separator: "-")
        guard p.count == 3 else { return date }
        return "\(p[2])/\(p[1])/\(p[0])"
    }
}

/// Histórico de versões do Amcrest Viewer, da mais nova para a mais antiga.
/// Ao lançar uma versão: acrescente no topo e atualize CFBundleShortVersionString no Info.plist.
public enum ReleaseNotes {
    public static let all: [Release] = [
        Release(version: "0.6.0", date: "2026-11-01", title: "Administração do hardware", changes: [
            "Nova janela Administração (engrenagem na barra ou ⌘,): câmeras, adicionar, usuário e senha, hardware e firmware, versões.",
            "A tela principal ficou só para assistir.",
            "Hardware e firmware: lê de cada câmera o modelo, a versão do firmware, o S/N e o hardware.",
            "Procurar na rede e busca por S/N varrem toda a faixa de IP interna, além do ONVIF.",
            "Se o IP salvo não responde e a câmera tem S/N, o app acha o IP novo na rede e atualiza o cadastro.",
            "O cadastro avisa que 37777 não é porta HTTP/RTSP.",
            "Tela de versões, com datas e o que mudou.",
        ]),
        Release(version: "0.5.0", date: "2026-11-01", title: "Procurar câmeras na rede", changes: [
            "Botão Procurar na rede (ONVIF): lista nome, IP e S/N e adiciona num clique.",
            "Cadastro por S/N sem precisar do endereço: o app acha o IP na rede.",
            "Correção: a busca funciona mesmo com VPN ligada no Mac.",
        ]),
        Release(version: "0.4.0", date: "2026-11-01", title: "IA no Mac", changes: [
            "Detecção de pessoas (Apple Vision), local, sem nuvem.",
            "Detecção de veículos (carro, moto, caminhão…), local, sem nuvem.",
        ]),
        Release(version: "0.3.0", date: "2026-11-01", title: "Número de série", changes: [
            "Campo Serial (S/N) por câmera, também lido do .txt.",
        ]),
        Release(version: "0.2.0", date: "2026-10-31", title: "Gravações e presets", changes: [
            "Gravações do microSD: lista por dia, assistir no VLC e baixar.",
            "Presets de PTZ com nome.",
        ]),
        Release(version: "0.1.0", date: "2026-10-31", title: "Primeira versão", changes: [
            "Grade ao vivo com todas as câmeras.",
            "Importação da lista de câmeras por .txt.",
            "Janela por câmera com PTZ, snapshot e abrir no VLC.",
            "Senhas no Keychain do macOS.",
        ]),
    ]

    /// A versão mais nova do histórico.
    public static var latest: Release { all[0] }

    /// Compara "0.10.0" > "0.9.1" número a número.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
