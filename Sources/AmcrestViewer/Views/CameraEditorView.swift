import SwiftUI
import AmcrestCore

/// Cadastro / edição de uma câmera, com teste de conexão.
struct CameraEditorView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss

    @State var camera: Camera
    let isNew: Bool
    /// Aberto por "Adicionar por S/N": destaca o campo do S/N.
    var bySerial = false

    @State private var password = ""
    @State private var testResult: String?
    @State private var testOK = false
    @State private var testing = false
    @State private var resolving = false
    @State private var work: Task<Void, Never>?
    @StateObject private var scanner = NetworkScanner()

    /// O cadastro pode ser por endereço OU por S/N (o app acha o IP na rede).
    private var trimmedHost: String { camera.host.trimmingCharacters(in: .whitespaces) }
    private var trimmedSerial: String { (camera.serialNumber ?? "").trimmingCharacters(in: .whitespaces) }
    private var busy: Bool { testing || resolving }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? (bySerial ? "Nova câmera por S/N" : "Nova câmera") : "Editar câmera")
                .font(.title2.weight(.semibold))
            if isNew && bySerial {
                Text("Preencha o nome, o S/N e a senha. Deixe o Endereço em branco: o app acha o IP na rede.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Nome", text: $camera.name, prompt: Text("Ex.: Garagem"))
                TextField("Endereço", text: $camera.host, prompt: Text("IP ou nome (ou deixe em branco e informe o S/N)"))
                HStack {
                    TextField("Porta HTTP", value: $camera.httpPort, format: .number.grouping(.never))
                    TextField("Porta RTSP", value: $camera.rtspPort, format: .number.grouping(.never))
                }
                Stepper("Canal: \(camera.channel)", value: $camera.channel, in: 1...128)
                Toggle("Usar HTTPS", isOn: $camera.useHTTPS)
                TextField("Serial (S/N)", text: serialBinding, prompt: Text("Ex.: AMC01853PN52UCB543 (o app acha o IP na rede)"))
                TextField("Usuário", text: $camera.username)
                SecureField("Senha", text: $password,
                            prompt: Text(isNew || !store.hasPassword(camera) ? "Senha da câmera" : "Deixe em branco para manter a atual"))
            }

            if let testResult {
                Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(testOK ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(trimmedHost.isEmpty && !trimmedSerial.isEmpty ? "Procurar e testar" : "Testar conexão") { test() }
                    .disabled((trimmedHost.isEmpty && trimmedSerial.isEmpty) || busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil || busy)
            }
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.secondary)
            } else if trimmedHost.isEmpty && !trimmedSerial.isEmpty {
                Text("Sem o endereço, o app procura a câmera na rede pelo S/N e preenche o IP.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { work?.cancel() }
    }

    private var validationError: String? {
        // Pode cadastrar por endereço OU por S/N (o app resolve o IP na rede).
        if trimmedHost.isEmpty && trimmedSerial.isEmpty {
            return "Informe o IP, o nome de rede ou o S/N da câmera."
        }
        if !trimmedHost.isEmpty && CameraListParser.hostPort(trimmedHost) == nil {
            return "Endereço inválido. Use um IP (192.168.1.10) ou nome (cam.local)."
        }
        if camera.httpPort == LanSweep.dahuaTCPPort || camera.rtspPort == LanSweep.dahuaTCPPort {
            return "37777 é a porta do app oficial da Amcrest, não serve aqui. Use HTTP 80 e RTSP 554."
        }
        if !(1...65535).contains(camera.httpPort) || !(1...65535).contains(camera.rtspPort) {
            return "Portas vão de 1 a 65535 (padrão: HTTP 80, RTSP 554)."
        }
        return nil
    }

    private var serialBinding: Binding<String> {
        Binding(get: { camera.serialNumber ?? "" },
                set: { camera.serialNumber = $0 })
    }

    /// Senha a usar agora: a digitada, ou a já salva.
    private var effectivePassword: String? {
        password.isEmpty ? store.password(for: camera) : password
    }

    private func normalized() -> Camera {
        var c = camera
        c.host = c.host.trimmingCharacters(in: .whitespaces)
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if c.name.isEmpty { c.name = c.host }
        let sn = (c.serialNumber ?? "").trimmingCharacters(in: .whitespaces)
        c.serialNumber = sn.isEmpty ? nil : sn
        return c
    }

    private func test() {
        testResult = nil
        work = Task {
            guard let cam = await resolvedCamera() else { return }
            if Task.isCancelled { return }
            testing = true
            defer { testing = false }
            camera = cam  // reflete o IP achado na tela
            let client = AmcrestClient(camera: cam, password: effectivePassword)
            do {
                let model = try await client.deviceType()
                testOK = true
                testResult = "Conectado em \(cam.host). Modelo: \(model)"
            } catch {
                // IP salvo não responde, mas tem S/N: procura o aparelho na rede interna e troca o IP.
                if !(error is CameraError), !trimmedSerial.isEmpty, !Task.isCancelled,
                   let moved = await relocated(from: cam) {
                    camera = moved
                    do {
                        let model = try await AmcrestClient(camera: moved, password: effectivePassword).deviceType()
                        testOK = true
                        testResult = "Achei pelo S/N em \(moved.host) (o IP \(cam.host) não respondia). Modelo: \(model). Clique em Salvar."
                    } catch {
                        testOK = false
                        testResult = "Achei pelo S/N em \(moved.host), mas: "
                            + (await LoginDiagnosis.explain(error, camera: moved, password: effectivePassword))
                    }
                    return
                }
                testOK = false
                testResult = (await LoginDiagnosis.explain(error, camera: cam, password: effectivePassword))
                    + (error is CameraError || trimmedSerial.isEmpty ? "" : " Também procurei o S/N \(trimmedSerial) em toda a rede interna do Mac e não achei.")
            }
        }
    }

    /// Procura o S/N na rede interna. Devolve a câmera com o IP novo, ou nil se não achou outro IP.
    private func relocated(from cam: Camera) async -> Camera? {
        resolving = true
        defer { resolving = false }
        guard let dev = await scanner.resolve(serial: trimmedSerial, username: cam.username,
                                              password: effectivePassword, preferredPort: cam.httpPort),
              dev.host != cam.host else { return nil }
        var c = cam
        c.host = dev.host
        c.httpPort = dev.httpPort
        c.useHTTPS = dev.useHTTPS
        return c
    }

    private func save() {
        testResult = nil
        work = Task {
            guard let cam = await resolvedCamera() else { return }
            // Se o editor já foi fechado (ex.: Cancelar durante a busca), não salva.
            if Task.isCancelled { return }
            camera = cam
            store.save(cam, password: password.isEmpty ? nil : password)
            dismiss()
        }
    }

    /// Devolve a câmera pronta para conectar: se o endereço estiver vazio e houver S/N,
    /// procura na rede pelo S/N e preenche IP/porta/HTTPS. Em caso de falha, mostra o motivo e devolve nil.
    private func resolvedCamera() async -> Camera? {
        var cam = normalized()
        guard cam.host.isEmpty else { return cam }
        let serial = trimmedSerial
        guard !serial.isEmpty else {
            testOK = false
            testResult = "Informe o IP ou o S/N da câmera."
            return nil
        }
        resolving = true
        defer { resolving = false }
        guard let dev = await scanner.resolve(serial: serial, username: cam.username,
                                              password: effectivePassword, preferredPort: cam.httpPort) else {
            testOK = false
            testResult = "Procurei na rede interna (ONVIF e toda a faixa de IP do Mac) e não achei o S/N \(serial). Confira se o aparelho está ligado nesta mesma rede. Se ele estiver em outro local, cadastre pelo IP."
            return nil
        }
        cam.host = dev.host
        cam.httpPort = dev.httpPort
        cam.useHTTPS = dev.useHTTPS
        if cam.name.isEmpty { cam.name = dev.displayName }
        return cam
    }
}
