import SwiftUI
import UniformTypeIdentifiers
import AmcrestCore

/// Janela principal: grade com todas as câmeras ao vivo (subfluxo, leve).
struct CameraGridView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.openWindow) private var openWindow

    @AppStorage("gridColumns") private var columns = 2
    @State private var showImporter = false
    @State private var importReport: ImportReport?
    @State private var editing: Camera?
    @State private var creating = false
    @State private var confirmRemove: Camera?

    var body: some View {
        Group {
            if store.cameras.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: max(columns, 1)),
                              spacing: 8) {
                        ForEach(store.cameras) { cam in
                            CameraTile(camera: cam)
                                .onTapGesture(count: 2) { openWindow(value: cam.id) }
                                .contextMenu { menu(for: cam) }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Colunas", selection: $columns) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Câmeras por linha")

                Button { showImporter = true } label: { Label("Importar .txt", systemImage: "square.and.arrow.down") }
                    .help("Importar a lista de câmeras de um arquivo .txt")
                Button { creating = true } label: { Label("Adicionar", systemImage: "plus") }
                    .help("Adicionar uma câmera manualmente")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text]) { result in
            if case .success(let url) = result { importReport = store.importTXT(from: url) }
        }
        .sheet(item: $importReport) { ImportReportView(report: $0).environmentObject(store) }
        .sheet(item: $editing) { CameraEditorView(camera: $0, isNew: false).environmentObject(store) }
        .sheet(isPresented: $creating) {
            CameraEditorView(camera: Camera(name: "", host: ""), isNew: true).environmentObject(store)
        }
        .alert("Remover \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })
        ) {
            Button("Remover", role: .destructive) { if let c = confirmRemove { store.remove(c) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A câmera e a senha salva no Keychain serão apagadas deste Mac.")
        }
        .alert("Atenção", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Nenhuma câmera cadastrada").font(.title2)
            Text("Importe o .txt com os endereços das câmeras ou adicione uma manualmente.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Importar .txt") { showImporter = true }.keyboardShortcut(.defaultAction)
                Button("Adicionar manualmente") { creating = true }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for cam: Camera) -> some View {
        Button("Abrir em janela") { openWindow(value: cam.id) }
        Button("Abrir no VLC (alta qualidade)") {
            if let msg = ExternalActions.openInVLC(cam, password: store.password(for: cam)) { store.errorMessage = msg }
        }
        Button("Copiar URL RTSP (sem senha)") { ExternalActions.copyRTSP(cam) }
        Divider()
        Button("Editar…") { editing = cam }
        Button("Remover…", role: .destructive) { confirmRemove = cam }
    }
}

/// Um quadro da grade.
struct CameraTile: View {
    let camera: Camera
    @EnvironmentObject private var store: CameraStore
    @StateObject private var feed = CameraFeed()

    var body: some View {
        FeedView(feed: feed, camera: camera)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onAppear { start() }
            .onDisappear { feed.stop() }
            .onChange(of: camera) { _ in start() }
            .onChange(of: store.revision) { _ in start() }
    }

    private func start() {
        feed.start(camera: camera, password: store.password(for: camera), quality: .sub)
    }
}

/// Imagem ao vivo + nome + selo de estado. Usada na grade e na janela da câmera.
struct FeedView: View {
    @ObservedObject var feed: CameraFeed
    let camera: Camera

    var body: some View {
        ZStack {
            Color.black
            if let img = feed.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            }
            statusOverlay
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(camera.name).font(.caption.weight(.semibold))
                if feed.status == .polling {
                    Text("· snapshots ~1/s").font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch feed.status {
        case .connecting where feed.image == nil:
            ProgressView().controlSize(.small).tint(.white)
        case .failed(let msg):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.caption).multilineTextAlignment(.center).foregroundStyle(.white)
            }
            .padding(10)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .padding()
        default:
            EmptyView()
        }
    }

    private var dotColor: Color {
        switch feed.status {
        case .live: return .green
        case .polling: return .yellow
        case .connecting: return .gray
        case .failed: return .red
        case .idle: return .gray
        }
    }
}
