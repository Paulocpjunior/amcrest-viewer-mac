import AppKit
import AmcrestCore

/// Ações que saem do app: VLC, Finder, área de transferência.
enum ExternalActions {
    static let vlcBundleID = "org.videolan.vlc"

    static var isVLCInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: vlcBundleID) != nil
    }

    /// Abre o fluxo RTSP principal (alta qualidade, com áudio) no VLC.
    /// Devolve uma mensagem de erro com a ação, ou nil se deu certo.
    @discardableResult
    static func openInVLC(_ camera: Camera, password: String?) -> String? {
        guard let vlc = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vlcBundleID) else {
            return "VLC não encontrado. Instale em videolan.org para ver em alta qualidade via RTSP."
        }
        guard let url = AmcrestEndpoints.rtsp(camera, quality: .main, password: password) else {
            return CameraError.invalidAddress.errorDescription
        }
        NSWorkspace.shared.open([url], withApplicationAt: vlc, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }

    /// Abre uma URL qualquer (RTSP de gravação, arquivo .dav) no VLC.
    @discardableResult
    static func openInVLC(url: URL?) -> String? {
        guard let vlc = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vlcBundleID) else {
            return "VLC não encontrado. Instale em videolan.org para assistir às gravações."
        }
        guard let url else { return CameraError.invalidAddress.errorDescription }
        NSWorkspace.shared.open([url], withApplicationAt: vlc, configuration: NSWorkspace.OpenConfiguration())
        return nil
    }

    /// Pasta das gravações baixadas: ~/Movies/Amcrest/<câmera>.
    static func recordingsFolder(for camera: Camera) throws -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        let dir = movies.appendingPathComponent("Amcrest", isDirectory: true)
            .appendingPathComponent(safeName(camera.name), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func safeName(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
    }

    /// Copia a URL RTSP SEM senha (para colar em outro programa sem vazar a credencial).
    static func copyRTSP(_ camera: Camera) {
        guard let url = AmcrestEndpoints.rtsp(camera, quality: .main) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Salva o snapshot em ~/Pictures/Amcrest e mostra no Finder.
    static func saveSnapshot(_ data: Data, camera: Camera) throws -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        let dir = pictures.appendingPathComponent("Amcrest", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safeName = camera.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let file = dir.appendingPathComponent("\(safeName)_\(fmt.string(from: Date())).jpg")
        try data.write(to: file, options: .atomic)
        NSWorkspace.shared.activateFileViewerSelecting([file])
        return file
    }
}
