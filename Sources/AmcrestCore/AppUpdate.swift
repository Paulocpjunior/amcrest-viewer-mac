import Foundation

/// Verificação de atualização do app, comparando a versão instalada com a publicada no GitHub
/// (Info.plist do ramo main). Só a lógica pura fica aqui, testável sem rede.
public enum AppUpdate {
    /// Info.plist publicado no ramo principal (repositório público).
    public static let publishedInfoPlistURL =
        URL(string: "https://raw.githubusercontent.com/Paulocpjunior/amcrest-viewer-mac/main/Resources/Info.plist")!
    /// Página do projeto, para ver a versão nova.
    public static let projectURL = URL(string: "https://github.com/Paulocpjunior/amcrest-viewer-mac")!

    public enum Status: Equatable, Sendable {
        case unknown
        case checking
        case upToDate(installed: String)
        /// Instalada é mais nova que a publicada (versão de teste).
        case aheadOfPublished(installed: String, published: String)
        case available(installed: String, published: String)
        case failed(String)

        public var summary: String {
            switch self {
            case .unknown: return "Ainda não verificada"
            case .checking: return "Verificando…"
            case .upToDate(let v): return "Em dia (\(v) é a mais nova)"
            case .aheadOfPublished(let i, let p): return "Versão de teste \(i) (publicada: \(p))"
            case .available(_, let p): return "Nova versão disponível: \(p)"
            case .failed(let m): return "Não foi possível verificar: \(m)"
            }
        }
    }

    /// Lê CFBundleShortVersionString de um Info.plist (XML ou binário).
    public static func version(fromInfoPlist data: Data) -> String? {
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let v = dict["CFBundleShortVersionString"] as? String,
              !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return v.trimmingCharacters(in: .whitespaces)
    }

    public static func compare(installed: String, published: String) -> Status {
        if ReleaseNotes.isNewer(published, than: installed) { return .available(installed: installed, published: published) }
        if ReleaseNotes.isNewer(installed, than: published) {
            return .aheadOfPublished(installed: installed, published: published)
        }
        return .upToDate(installed: installed)
    }

    /// Mostrar "O que há de novo" ao abrir? Sim quando a versão mudou desde a última abertura.
    public static func shouldShowWhatsNew(lastSeen: String?, installed: String) -> Bool {
        guard let lastSeen, !lastSeen.isEmpty else { return true }
        return lastSeen != installed
    }

    /// Novidades das versões entre a última vista (exclusive) e a instalada (inclusive).
    public static func releasesSince(_ lastSeen: String?, upTo installed: String,
                                     in all: [Release] = ReleaseNotes.all) -> [Release] {
        all.filter { r in
            !ReleaseNotes.isNewer(r.version, than: installed)
                && (lastSeen.map { ReleaseNotes.isNewer(r.version, than: $0) } ?? (r.version == installed))
        }
    }
}

/// Resumo do estado das câmeras para a barra de status.
public enum CameraHealth: String, Sendable, CaseIterable {
    case live, polling, connecting, failed, unknown

    public var label: String {
        switch self {
        case .live: return "ao vivo"
        case .polling: return "snapshots"
        case .connecting: return "conectando"
        case .failed: return "com erro"
        case .unknown: return "sem dados"
        }
    }

    /// Contagem por estado, na ordem de exibição, omitindo os zerados.
    public static func counts(_ states: [CameraHealth]) -> [(CameraHealth, Int)] {
        allCases.compactMap { h in
            let n = states.filter { $0 == h }.count
            return n > 0 ? (h, n) : nil
        }
    }
}
