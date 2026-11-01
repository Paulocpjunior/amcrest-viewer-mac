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
/// 3. Queda de rede: tenta de novo (5 s, depois mais espaçado). Senha errada: para e pede correção.
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

    /// IA: o que está na cena agora (pessoa, veículo), com janela de hold por tipo,
    /// para o selo não piscar quando um quadro falha a detecção.
    @Published private(set) var present: Set<DetectionKind> = []

    /// Conveniências para a interface.
    var personPresent: Bool { present.contains(.person) }
    var vehiclePresent: Bool { present.contains(.vehicle) }

    /// O que a IA deve procurar nesta câmera. Vazio = IA desligada.
    var detectKinds: Set<DetectionKind> = [] {
        didSet {
            guard detectKinds != oldValue else { return }
            // Invalida qualquer análise em voo: um resultado de antes da troca
            // não pode reacender um selo depois de religar.
            detectEpoch &+= 1
            analyzing = false
            for kind in oldValue.subtracting(detectKinds) { gates[kind] = nil }
            present = present.intersection(detectKinds)
        }
    }

    /// Liga/desliga os detectores a partir dos botões da interface.
    func setDetection(people: Bool, vehicles: Bool) {
        var kinds: Set<DetectionKind> = []
        if people { kinds.insert(.person) }
        if vehicles { kinds.insert(.vehicle) }
        detectKinds = kinds
    }

    /// Ritmo da análise (usa só o throttle do gate) e um gate por tipo para o hold.
    private var pacer = DetectionGate()
    private var gates: [DetectionKind: DetectionGate] = [:]
    private var analyzing = false
    /// Muda a cada vez que a detecção é ligada/desligada; descarta trabalho antigo.
    private var detectEpoch = 0
    private let detectQueue = DispatchQueue(label: "amcrest.detect", qos: .utility)

    private var camera: Camera?
    private var password: String?
    private var quality: StreamQuality = .sub
    private var session: URLSession?
    private var pollTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// Cada conexão tem um número; respostas de conexões antigas são ignoradas.
    private var generation = 0
    private var active = false
    /// Falhas seguidas: espaça as novas tentativas (5 s, 15 s, 60 s…) para não insistir
    /// com a câmera — várias tentativas seguidas fazem a Amcrest bloquear o login por até 30 min.
    private var consecutiveFailures = 0

    /// 5 s nas duas primeiras falhas, depois 15 s, depois 60 s.
    nonisolated static func retryDelay(afterFailures n: Int) -> Double {
        n <= 2 ? 5 : (n <= 4 ? 15 : 60)
    }

    func start(camera: Camera, password: String?, quality: StreamQuality) {
        stop()
        consecutiveFailures = 0
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
        present = []
        pacer = DetectionGate()
        gates = [:]
        analyzing = false
        detectEpoch &+= 1
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
        // O request do MJPEG já leva o login no cabeçalho (authorizedRequest, abaixo). Sem credencial
        // no delegate, a câmera não recebe uma 2ª tentativa de login se a 1ª for recusada.
        delegate.credential = nil
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
        // Login Digest montado pelo app (desafio novo a cada conexão do vídeo).
        let cam = camera, pwd = password
        Task { [weak self] in
            let request: URLRequest
            do {
                request = try await CameraHTTP.authorizedRequest(url, camera: cam, password: pwd, fresh: true)
            } catch {
                guard let self, gen == self.generation, self.active else { return }
                self.fail(CameraError.friendly(error, camera: cam), retry: true)
                return
            }
            guard let self, gen == self.generation, self.active else { return }
            s.dataTask(with: request).resume()
        }
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
            var badImages = 0
            while !Task.isCancelled {
                do {
                    let data = try await client.snapshot()
                    if let img = NSImage(data: data) {
                        badImages = 0
                        self?.show(img, gen: gen)
                    } else {
                        badImages += 1
                        if badImages >= 3 {
                            guard let self, gen == self.generation else { return }
                            self.fail(CameraError.unexpectedContent.errorDescription!, retry: true)
                            return
                        }
                    }
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
        consecutiveFailures = 0
        image = img
        lastFrameAt = Date()
        analyze(img, gen: gen)
    }

    // MARK: - IA (detecção no Mac, via Vision)

    /// Roda os detectores num quadro, com throttle, fora da main thread.
    private func analyze(_ img: NSImage, gen: Int) {
        guard !detectKinds.isEmpty, !analyzing else { return }
        guard pacer.shouldAnalyze(now: Date()) else { return }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let kinds = detectKinds
        analyzing = true
        let epoch = detectEpoch
        detectQueue.async { [weak self] in
            let found = SceneDetector.detect(inCGImage: cg, kinds: kinds)
            Task { @MainActor in self?.finishAnalysis(found: found, requested: kinds, gen: gen, epoch: epoch) }
        }
    }

    private func finishAnalysis(found: Set<DetectionKind>, requested: Set<DetectionKind>, gen: Int, epoch: Int) {
        // A detecção mudou depois que esta análise começou: descarta, sem mexer
        // no `analyzing` de uma análise mais nova que já esteja em voo.
        guard epoch == detectEpoch else { return }
        analyzing = false
        guard gen == generation, active else { return }
        let now = Date()
        var current: Set<DetectionKind> = []
        for kind in requested where detectKinds.contains(kind) {
            var gate = gates[kind] ?? DetectionGate()
            if gate.record(detected: found.contains(kind), now: now).isPresent { current.insert(kind) }
            gates[kind] = gate
        }
        present = current
    }

    private func fail(_ message: String, retry: Bool) {
        session?.invalidateAndCancel()
        session = nil
        pollTask?.cancel()
        pollTask = nil
        generation += 1
        status = .failed(message)
        // Sem quadros novos, a janela de hold nunca é reavaliada: ao falhar/reconectar,
        // limpa o estado para o selo não ficar preso numa detecção antiga.
        present = []
        pacer = DetectionGate()
        gates = [:]
        guard retry else { return }
        consecutiveFailures += 1
        let delay = Self.retryDelay(afterFailures: consecutiveFailures)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connectMJPEG()
        }
    }
}
