import SwiftUI
import AmcrestCore

/// Resultado da importação: o que entrou, o que já existia, o que não foi entendido.
/// Também permite definir de uma vez a senha das câmeras que vieram sem senha.
struct ImportReportView: View {
    let report: ImportReport
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = "admin"
    @State private var password = ""
    @State private var applied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Importação de \(report.fileName)").font(.title2.weight(.semibold))

            HStack(spacing: 18) {
                counter("\(report.added.count)", "adicionadas", .green)
                counter("\(report.duplicates.count)", "já existiam", .secondary)
                counter("\(report.rejected.count)", "não entendidas", report.rejected.isEmpty ? .secondary : .orange)
            }

            if report.added.isEmpty && report.duplicates.isEmpty && report.rejected.isEmpty {
                Text("O arquivo não tem nenhuma linha com câmera. Coloque uma câmera por linha (ex.: Garagem 192.168.1.10).")
                    .foregroundStyle(.orange)
            }

            if !report.rejected.isEmpty {
                GroupBox("Linhas não importadas (corrija o .txt e importe de novo)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(report.rejected, id: \.lineNumber) { r in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Linha \(r.lineNumber): \(r.line)").font(.system(.caption, design: .monospaced))
                                    Text(r.reason).font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }

            if !report.duplicates.isEmpty {
                Text("Já cadastradas (mesmo endereço e canal): "
                     + report.duplicates.map { "linha \($0.line) (\($0.camera.host))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !report.missingPassword.isEmpty {
                GroupBox("Senha das \(report.missingPassword.count) câmeras importadas sem senha") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Se todas usam o mesmo login, informe aqui. A senha fica só no Keychain deste Mac. Senhas diferentes: edite cada câmera depois.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            TextField("Usuário", text: $username).frame(width: 120)
                            SecureField("Senha", text: $password)
                            Button(applied ? "Aplicada" : "Aplicar") {
                                store.applyCredentials(to: report.missingPassword, username: username, password: password)
                                applied = true
                            }
                            .disabled(password.isEmpty || applied)
                        }
                    }
                    .padding(4)
                }
            }

            HStack {
                Spacer()
                Button("Concluir") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func counter(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title.weight(.semibold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
