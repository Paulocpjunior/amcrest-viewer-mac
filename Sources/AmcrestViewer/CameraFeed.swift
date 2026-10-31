import AppKit
import AmcrestCore

/// Delegado de uma sessão MJPEG. Roda na fila da sessão; entrega quadros por closure.
private final class MJPEGSessionDelegate: NSObject, URLSessionDataDelegate {
    var credential: URLCredential?
    /// Devolve `true` para continuar recebendo o corpo.
    var onResponse: (@Sendable (HTTPURLResponse) -> Bool)?
    var onFrame: (@Sendable (Data) -> Void)?
    var onFinish: (@Sendable (Error?) -> Void)?
    private var extractor = MJPEGFrameExtractor()

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        AuthHandling.handle(challenge, credential: credential, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        extractor = MJPEGFrameExtractor()
        completionHandler((onResponse?(http) ?? true) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for frame in extractor.append(data) { onFrame?(frame) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onFinish?(error)
    }
}

/// Vídeo ao vivo de uma câmera.
///
/// 1. Tenta MJPEG (`/cgi-bin/mjpg/video.cgi`), que dá movimento fluido sem dependências.
/// 2. Se a câmera não oferecer MJPEG naquele fluxo, cai para snapshots seguidos (~1 por segundo)
///    e diz isso na tela: o usuário sabe que não é vídeo contínuo.
/// 3. Queda de rede: tenta de novo a cada 5 s. Senha errada: para e pede correção.
@MainActor
final class CameraFeed: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case live
        case polling
        case failed(String)
    }

    @Published private(set) var image: NSImage?
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastFrameAt: Date?

    private var camera: Camera?
    private var password: String?
    private var quality: StreamQuality = .sub
    private var session: URLSession?
    private var pollTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// Cada conexão tem um número; respostas de conexões antigas são ignoradas.
    private var generation = 0
    private var active = false

    func start(camera: Camera, password: String?, quality: StreamQuality) {
        stop()
        self.camera = camera
        self.password = password
        self.quality = quality
        active = true
        connectMJPEG()
    }

    func stop() {
        active = false
        generation += 1
        session?.invalidateAndCancel()
        session = nil
        pollTask?.cancel()
        pollTask = nil
        retryTask?.cancel()
        retryTask = nil
        status = .idle
    }

    // MARK: - MJPEG

    private func connectMJPEG() {
        guard active, let camera else { return }
        guard let url = AmcrestEndpoints.mjpeg(camera, quality: quality) else {
            status = .failed(CameraError.invalidAddress.errorDescription!)
            return
        }
        generation += 1
        let gen = generation
        status = .connecting

        let delegate = MJPEGSessionDelegate()
        delegate.credential = AuthHandling.credential(for: camera, password: password)
        delegate.onResponse = { [weak self] http in
            let isMultipart = http.mimeType?.lowercased().hasPrefix("multipart/") ?? false
            let ok = http.statusCode == 200 && isMultipart
            Task { @MainActor in self?.handleMJPEGResponse(http, isMultipart: isMultipart, gen: gen) }
            return ok
        }
        delegate.onFrame = { [weak self] data in
            guard let img = NSImage(data: data) else { return }
            Task { @MainActor in self?.show(img, gen: gen) }
        }
        delegate.onFinish = { [weak self] error in
            Task { @MainActor in self?.mjpegFinished(error, gen: gen) }
        }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: AuthHandling.makeConfiguration(requestTimeout: 10),
                           delegate: delegate, delegateQueue: queue)
        session?.invalidateAndCancel()
        session = s
        s.dataTask(with: url).resume()
    }

    private func handleMJPEGResponse(_ http: HTTPURLResponse, isMultipart: Bool, gen: Int) {
        guard gen == generation, active else { return }
        if http.statusCode == 401 {
            fail(CameraError.unauthorized.errorDescription!, retry: false)
        } else if http.statusCode == 200 && isMultipart {
            status = .live
        } else {
            // Sem MJPEG neste fluxo (404, 400 ou HTML): usa snapshots.
            startPolling()
        }
    }

    private func mjpegFinished(_ error: Error?, gen: Int) {
        guard gen == generation, active, let camera else { return }
        guard status == .live || status == .connecting else { return }
        let message = error.map { CameraError.friendly($0, camera: camera) }
            ?? "A câmera encerrou o vídeo. Reconectando…"
        fail(message, retry: true)
    }

    // MARK: - Snapshots seguidos

    private func startPolling() {
        guard active, let camera else { return }
        session?.invalidateAndCancel()
        session = nil
        generation += 1
        let gen = generation
        status = .polling
        let client = AmcrestClient(camera: camera, password: password)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let data = try await client.snapshot()
                    if let img = NSImage(data: data) { self?.show(img, gen: gen) }
                } catch {
                    guard let self, gen == self.generation else { return }
                    self.fail(CameraError.friendly(error, camera: camera), retry: !CameraError.isUnauthorized(error))
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Comum

    private func show(_ img: NSImage, gen: Int) {
        guard gen == generation, active else { return }
        image = img
        lastFrameAt = Date()
    }

    private func fail(_ message: String, retry: Bool) {
        session?.invalidateAndCancel()
        session = nil
        pollTask?.cancel()
        pollTask = nil
        generation += 1
        status = .failed(message)
        guard retry else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connectMJPEG()
        }
    }
}
