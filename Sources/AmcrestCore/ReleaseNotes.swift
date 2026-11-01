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
        Release(version: "0.6.3", date: "2026-11-01", title: "Login nas câmeras corrigido", changes: [
            "O app agora faz o login Digest na câmera ele mesmo, em vez de deixar o macOS negociar. Corrige câmeras na mesma rede que abriam no Safari mas ficavam sem imagem no app.",
            "Se a câmera pede login e some depois de receber a senha, o app diz isso, em vez de \"não respondeu a tempo\".",
            "Testar todas agora e Testar conexão conferem a senha pelo mesmo login da página da câmera (o do Safari) e dizem se a senha está errada, se o usuário foi bloqueado ou se falta liberar a API na câmera.",
        ]),
        Release(version: "0.6.2", date: "2026-11-01", title: "Atualização e status", changes: [
            "Janela de Atualização: versão instalada, se há versão nova publicada e as novidades. Abre sozinha depois de cada atualização e pelo menu Procurar atualizações….",
            "Barra de status no rodapé da grade: quantas câmeras ao vivo, em snapshots, conectando e com erro, mais a versão do app.",
            "Administração → Status: o estado de cada câmera com o motivo do erro e o botão Testar todas agora.",
        ]),
        Release(version: "0.6.1", date: "2026-11-01", title: "Mensagens mais claras quando a imagem não vem", changes: [
            "Quando a câmera não responde ao login, o quadro mostra o motivo em vez de ficar preto.",
            "Se a câmera manda algo que não é imagem, o app avisa.",
            "Novas tentativas ficam mais espaçadas (5 s, 15 s, 60 s) para não bloquear o login da câmera.",
        ]),
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
