import SwiftUI
import AppKit
import AmcrestCore

/// Gravações do cartão microSD de uma câmera: escolhe o dia, lista os vídeos,
/// assiste no VLC (RTSP de reprodução) ou baixa o arquivo .dav.
struct RecordingsView: View {
    let camera: Camera
    let password: String?
    @Environment(\.dismiss) private var dismiss

    @State private var day = Date()
    @State private var files: [RecordingFile] = []
    @State private var loading = false
    @State private var searched = false
    @State private var downloading: Set<String> = []
    @State private var message: String?
    @State private var selection: RecordingFile.ID?

    @State private var hasVLC = ExternalActions.isVLCInstalled

    private var client: AmcrestClient { AmcrestClient(camera: camera, password: password) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gravações do microSD").font(.title3.bold())
                Spacer()
                DatePicker("Dia", selection: $day, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                Button { Task { await search() } } label: {
                    Label("Buscar", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading)
            }

            if !hasVLC {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Para assistir aqui é preciso o VLC (gratuito). Sem ele, use Baixar e abra o arquivo .dav no VLC depois.")
                        HStack {
                            Link("Baixar o VLC", destination: URL(string: "https://www.videolan.org/vlc/download-macos.html")!)
                            Button("Já instalei") { hasVLC = ExternalActions.isVLCInstalled }
                                .buttonStyle(.link)
                        }
                    }
                }
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }

            content
                .frame(minWidth: 620, minHeight: 320)

            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Abrir pasta") { openFolder() }
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .task { await search() }
        .onChange(of: day) { _ in Task { await search() } }
        .alert("Aviso", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    @ViewBuilder private var content: some View {
        if loading {
            VStack { Spacer(); ProgressView("Buscando no cartão…"); Spacer() }.frame(maxWidth: .infinity)
        } else if files.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "sdcard").font(.largeTitle).foregroundStyle(.secondary)
                Text(searched ? "Nenhum vídeo gravado neste dia." : "Escolha um dia e clique em Buscar.")
                Text("Se esperava gravações, confira na câmera se o cartão está instalado e a gravação ativada.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            Table(files, selection: $selection) {
                TableColumn("Início") { f in Text(f.start, format: .dateTime.hour().minute().second()) }
                    .width(80)
                TableColumn("Fim") { f in Text(f.end, format: .dateTime.hour().minute().second()) }
                    .width(80)
                TableColumn("Duração") { f in Text(Self.duration(f.duration)) }
                    .width(70)
                TableColumn("Tipo") { f in Text(Self.kind(f)) }
                TableColumn("Tamanho") { f in Text(f.length.map(Self.size) ?? "–") }
                    .width(80)
                TableColumn("") { f in
                    HStack(spacing: 6) {
                        Button { play(f) } label: { Image(systemName: "play.fill") }
                            .help(hasVLC ? "Assistir no VLC" : "Instale o VLC para assistir")
                            .disabled(!hasVLC)
                        if downloading.contains(f.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { Task { await download(f) } } label: { Image(systemName: "arrow.down.circle") }
                                .help("Baixar para Filmes/Amcrest")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .width(70)
            }
        }
    }

    private var summary: String {
        guard !files.isEmpty else { return "" }
        let total = files.reduce(0) { $0 + $1.duration }
        return "\(files.count) vídeos, \(Self.duration(total)) no total. Horários no fuso do Mac."
    }

    // MARK: - Ações

    private func search() async {
        loading = true
        defer { loading = false; searched = true }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? start
        do {
            files = try await client.recordings(from: start, to: end)
        } catch {
            files = []
            message = CameraError.friendly(error, camera: camera)
        }
    }

    private func play(_ f: RecordingFile) {
        let url = AmcrestEndpoints.rtspPlayback(camera, from: f.start, to: f.end, password: password)
        if let err = ExternalActions.openInVLC(url: url) { message = err }
    }

    private func download(_ f: RecordingFile) async {
        downloading.insert(f.id)
        defer { downloading.remove(f.id) }
        do {
            let dir = try ExternalActions.recordingsFolder(for: camera)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let dest = dir.appendingPathComponent("\(ExternalActions.safeName(camera.name))_\(fmt.string(from: f.start)).dav")
            try await client.download(f, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            message = CameraError.friendly(error, camera: camera)
        }
    }

    private func openFolder() {
        if let dir = try? ExternalActions.recordingsFolder(for: camera) {
            NSWorkspace.shared.open(dir)
        }
    }

    // MARK: - Formatação

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func kind(_ f: RecordingFile) -> String {
        if f.events.contains(where: { $0.localizedCaseInsensitiveContains("motion") }) { return "Movimento" }
        if f.flags.contains("Manual") { return "Manual" }
        if f.flags.contains("Event") || !f.events.isEmpty { return "Evento" }
        return "Contínua"
    }
}
