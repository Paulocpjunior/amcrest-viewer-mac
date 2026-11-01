import SwiftUI
import AmcrestCore

/// Cadastro / edição de uma câmera, com teste de conexão.
struct CameraEditorView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss

    @State var camera: Camera
    let isNew: Bool

    @State private var password = ""
    @State private var testResult: String?
    @State private var testOK = false
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Nova câmera" : "Editar câmera").font(.title2.weight(.semibold))

            Form {
                TextField("Nome", text: $camera.name, prompt: Text("Ex.: Garagem"))
                TextField("Endereço", text: $camera.host, prompt: Text("IP ou nome. Ex.: 192.168.1.10"))
                HStack {
                    TextField("Porta HTTP", value: $camera.httpPort, format: .number.grouping(.never))
                    TextField("Porta RTSP", value: $camera.rtspPort, format: .number.grouping(.never))
                }
                Stepper("Canal: \(camera.channel)", value: $camera.channel, in: 1...128)
                Toggle("Usar HTTPS", isOn: $camera.useHTTPS)
                TextField("Usuário", text: $camera.username)
                TextField("Serial (S/N)", text: $camera.serial,
                          prompt: Text("Opcional. Ex.: AMC01858719C691882"))
                SecureField("Senha", text: $password,
                            prompt: Text(isNew || !store.hasPassword(camera) ? "Senha da câmera" : "Deixe em branco para manter a atual"))
            }

            if let testResult {
                Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(testOK ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Testar conexão") { test() }
                    .disabled(camera.host.isEmpty || testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var validationError: String? {
        let host = camera.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return "Informe o IP ou o nome de rede da câmera." }
        if CameraListParser.hostPort(host) == nil { return "Endereço inválido. Use um IP (192.168.1.10) ou nome (cam.local)." }
        if !(1...65535).contains(camera.httpPort) || !(1...65535).contains(camera.rtspPort) {
            return "Portas vão de 1 a 65535 (padrão: HTTP 80, RTSP 554)."
        }
        return nil
    }

    /// Senha a usar agora: a digitada, ou a já salva.
    private var effectivePassword: String? {
        password.isEmpty ? store.password(for: camera) : password
    }

    private func normalized() -> Camera {
        var c = camera
        c.host = c.host.trimmingCharacters(in: .whitespaces)
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        c.serial = c.serial.trimmingCharacters(in: .whitespaces)
        if c.name.isEmpty { c.name = c.host }
        return c
    }

    private func test() {
        testing = true
        testResult = nil
        let cam = normalized()
        let client = AmcrestClient(camera: cam, password: effectivePassword)
        Task {
            defer { testing = false }
            do {
                let model = try await client.deviceType()
                testOK = true
                testResult = "Conectado. Modelo: \(model)"
            } catch {
                testOK = false
                testResult = CameraError.friendly(error, camera: cam)
            }
        }
    }

    private func save() {
        store.save(normalized(), password: password.isEmpty ? nil : password)
        dismiss()
    }
}
