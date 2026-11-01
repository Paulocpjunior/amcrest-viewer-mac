import Foundation
import Security
import AmcrestCore

/// Senhas no Keychain do macOS. Nunca em arquivo, nunca em log.
enum Keychain {
    static let service = "com.paulocpjunior.AmcrestViewer"

    static func set(_ password: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Resultado de uma importação de .txt, para mostrar ao usuário sem esconder nada.
struct ImportReport: Identifiable {
    let id = UUID()
    let fileName: String
    var added: [Camera] = []
    var duplicates: [(line: Int, camera: Camera)] = []
    var rejected: [CameraListParser.Rejected] = []
    /// Câmeras importadas que ficaram sem senha.
    var missingPassword: [Camera] = []
}

/// Lista de câmeras, gravada em ~/Library/Application Support/AmcrestViewer/cameras.json.
@MainActor
final class CameraStore: ObservableObject {
    @Published private(set) var cameras: [Camera] = []
    @Published var errorMessage: String?
    /// Muda a cada gravação (inclusive troca de senha) para as telas reconectarem.
    @Published private(set) var revision = 0
    /// A janela de Administração está aberta: ela mostra os avisos, e a grade não repete.
    @Published var adminVisible = false
    /// Procurando IPs novos pelo S/N.
    @Published private(set) var relocating = false
    /// Resumo da última atualização de IP pelo S/N (nil se nada mudou).
    @Published var lastRelocation: String?

    // MARK: Status das câmeras e do app

    /// Estado de cada câmera, informado pelos quadros da grade (ou pelo "Testar todas").
    struct FeedReport: Equatable {
        var health: CameraHealth
        var message: String?
        var at: Date
    }
    @Published private(set) var reports: [UUID: FeedReport] = [:]

    func report(_ id: UUID, health: CameraHealth, message: String? = nil) {
        let new = FeedReport(health: health, message: message, at: Date())
        if reports[id]?.health == new.health && reports[id]?.message == new.message { return }
        reports[id] = new
    }

    func health(of camera: Camera) -> CameraHealth { reports[camera.id]?.health ?? .unknown }

    /// Testa todas as câmeras agora (pedido leve: modelo do aparelho), em paralelo.
    func testAll() async {
        let jobs = cameras.map { ($0, password(for: $0)) }
        for (cam, _) in jobs { report(cam.id, health: .connecting) }
        await withTaskGroup(of: (UUID, CameraHealth, String?).self) { group in
            for (cam, pwd) in jobs {
                group.addTask {
                    do {
                        let model = try await AmcrestClient(camera: cam, password: pwd).deviceType()
                        return (cam.id, .live, "Responde (\(model))")
                    } catch {
                        return (cam.id, .failed, CameraError.friendly(error, camera: cam))
                    }
                }
            }
            for await (id, h, msg) in group { report(id, health: h, message: msg) }
        }
    }

    /// Versão instalada (do Info.plist do app; rodando por `swift run`, a do histórico).
    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ReleaseNotes.latest.version
    }
    var installedBuild: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }

    @Published private(set) var updateStatus: AppUpdate.Status = .unknown
    @Published private(set) var updateCheckedAt: Date?

    /// Compara com a versão publicada no GitHub (repositório público, só leitura).
    func checkForUpdates() async {
        if updateStatus == .checking { return }
        updateStatus = .checking
        var req = URLRequest(url: AppUpdate.publishedInfoPlistURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let published = AppUpdate.version(fromInfoPlist: data) else {
                updateStatus = .failed("resposta inesperada do GitHub")
                return
            }
            updateStatus = AppUpdate.compare(installed: installedVersion, published: published)
        } catch {
            updateStatus = .failed("sem internet ou GitHub fora do ar")
        }
        updateCheckedAt = Date()
    }

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("AmcrestViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cameras.json")
        load()
    }

    func camera(id: UUID) -> Camera? { cameras.first { $0.id == id } }

    func password(for camera: Camera) -> String? { Keychain.get(account: camera.id.uuidString) }

    func hasPassword(_ camera: Camera) -> Bool { !(password(for: camera) ?? "").isEmpty }

    /// `password == nil` mantém a senha atual; string vazia apaga.
    func save(_ camera: Camera, password: String?) {
        if let i = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[i] = camera
        } else {
            cameras.append(camera)
        }
        if let password {
            if password.isEmpty { Keychain.delete(account: camera.id.uuidString) }
            else { Keychain.set(password, account: camera.id.uuidString) }
        }
        revision += 1
        persist()
    }

    func remove(_ camera: Camera) {
        reports[camera.id] = nil
        cameras.removeAll { $0.id == camera.id }
        Keychain.delete(account: camera.id.uuidString)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        cameras.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Aplica o mesmo usuário e senha a várias câmeras (caso comum: todas com a mesma senha).
    func applyCredentials(to targets: [Camera], username: String, password: String) {
        for cam in targets {
            guard var current = camera(id: cam.id) else { continue }
            if !username.isEmpty { current.username = username }
            save(current, password: password)
        }
    }

    /// Para cada aparelho com S/N cujo IP salvo não responde, procura o S/N na rede interna
    /// (ONVIF + faixa de IP) e, se achar em outro IP, atualiza o cadastro. Todos os canais
    /// do mesmo aparelho (mesmo IP antigo, ex.: NVR) mudam juntos. Devolve o que mudou.
    @discardableResult
    func relocateBySerial() async -> [String] {
        guard !relocating else { return [] }
        relocating = true
        defer { relocating = false }
        var moved: [String] = []
        var seen = Set<String>()
        for cam in cameras {
            let sn = (cam.serialNumber ?? "").trimmingCharacters(in: .whitespaces)
            let key = OnvifDiscovery.normalizeSerial(sn)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let pwd = password(for: cam)
            if !cam.host.isEmpty, await Self.answers(cam, password: pwd) { continue }
            guard let dev = await NetworkScanner.find(serial: sn, username: cam.username, password: pwd,
                                                      preferredPort: cam.httpPort),
                  dev.host != cam.host else { continue }
            let oldHost = cam.host
            for var c in cameras where c.id == cam.id
                || (!oldHost.isEmpty && c.host == oldHost)
                || OnvifDiscovery.normalizeSerial(c.serialNumber ?? "") == key {
                c.host = dev.host
                c.httpPort = dev.httpPort
                c.useHTTPS = dev.useHTTPS
                save(c, password: nil)
            }
            moved.append("\(cam.name): \(oldHost.isEmpty ? "sem IP" : oldHost) → \(dev.host)")
        }
        lastRelocation = moved.isEmpty ? nil : "IP atualizado pelo S/N: " + moved.joined(separator: "; ")
        return moved
    }

    /// O aparelho responde no IP salvo? (Qualquer resposta HTTP conta, até senha errada.)
    private static func answers(_ cam: Camera, password: String?) async -> Bool {
        do {
            _ = try await AmcrestClient(camera: cam, password: password).deviceType()
            return true
        } catch is CameraError {
            return true
        } catch {
            return false
        }
    }

    func importTXT(from url: URL) -> ImportReport {
        var report = ImportReport(fileName: url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Não consegui ler \(url.lastPathComponent). Confira se o arquivo existe e se você tem permissão de leitura."
            return report
        }
        // Bloco de Notas do Windows costuma gravar em Windows-1252.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)

        let parsed = CameraListParser.parse(text)
        report.rejected = parsed.rejected

        for item in parsed.cameras {
            let isDuplicate = cameras.contains {
                $0.host.caseInsensitiveCompare(item.camera.host) == .orderedSame && $0.channel == item.camera.channel
            }
            if isDuplicate {
                report.duplicates.append((item.lineNumber, item.camera))
                continue
            }
            save(item.camera, password: item.password)
            report.added.append(item.camera)
            if item.password == nil { report.missingPassword.append(item.camera) }
        }
        return report
    }

    // MARK: - Arquivo

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            cameras = try JSONDecoder().decode([Camera].self, from: data)
        } catch {
            errorMessage = "A lista de câmeras salva está corrompida (\(fileURL.path)). Renomeie o arquivo e importe o .txt de novo."
        }
    }

    private func persist() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(cameras).write(to: fileURL, options: .atomic)
        } catch {
            errorMessage = "Não consegui salvar a lista de câmeras em \(fileURL.path): \(error.localizedDescription)"
        }
    }
}
