import SwiftUI
import AmcrestCore

/// Janela principal: grade com todas as câmeras ao vivo (subfluxo, leve).
struct CameraGridView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.openWindow) private var openWindow

    @AppStorage("gridColumns") private var columns = 2
    @AppStorage("detectPeople") private var detectPeople = false
    @AppStorage("detectVehicles") private var detectVehicles = false
    @State private var editing: Camera?
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

                Toggle(isOn: $detectPeople) { Label("Detectar pessoas", systemImage: "figure.walk") }
                    .toggleStyle(.button)
                    .help("IA no seu Mac: marca as câmeras onde aparece uma pessoa. Nada vai para a nuvem.")

                Toggle(isOn: $detectVehicles) { Label("Detectar veículos", systemImage: "car.fill") }
                    .toggleStyle(.button)
                    .help("IA no seu Mac: marca as câmeras onde aparece um veículo. Nada vai para a nuvem.")

                Button { openWindow(id: AdminWindow.id) } label: { Label("Administração", systemImage: "gearshape") }
                    .help("Câmeras, senhas, procurar na rede, importar e hardware (⌘,)")
            }
        }
        .sheet(item: $editing) { CameraEditorView(camera: $0, isNew: false).environmentObject(store) }
        .alert("Remover \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })
        ) {
            Button("Remover", role: .destructive) { if let c = confirmRemove { store.remove(c) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A câmera e a senha salva no Keychain serão apagadas deste Mac.")
        }
        .alert("Atenção", isPresented: Binding(
            // Com a Administração aberta, o aviso aparece lá (não repete aqui).
            get: { store.errorMessage != nil && !store.adminVisible }, set: { if !$0 { store.errorMessage = nil } })
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
            Text("Cadastre as câmeras na Administração: procurar na rede, por S/N, por IP ou importar um .txt.")
                .foregroundStyle(.secondary)
            Button("Abrir Administração") { openWindow(id: AdminWindow.id) }
                .keyboardShortcut(.defaultAction)
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
        Divider()
        Button("Administração…") { openWindow(id: AdminWindow.id) }
    }
}

/// Um quadro da grade.
struct CameraTile: View {
    let camera: Camera
    @EnvironmentObject private var store: CameraStore
    @AppStorage("detectPeople") private var detectPeople = false
    @AppStorage("detectVehicles") private var detectVehicles = false
    @StateObject private var feed = CameraFeed()

    var body: some View {
        FeedView(feed: feed, camera: camera)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onAppear { start() }
            .onDisappear { feed.stop() }
            .onChange(of: camera) { _ in start() }
            .onChange(of: store.revision) { _ in start() }
            .onChange(of: detectPeople) { _ in syncDetection() }
            .onChange(of: detectVehicles) { _ in syncDetection() }
    }

    private func syncDetection() {
        feed.setDetection(people: detectPeople, vehicles: detectVehicles)
    }

    private func start() {
        syncDetection()
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
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                if feed.personPresent { badge("Pessoa", "figure.walk", .red) }
                if feed.vehiclePresent { badge("Veículo", "car.fill", .blue) }
            }
            .padding(8)
        }
        .animation(.easeInOut(duration: 0.2), value: feed.present)
    }

    private func badge(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
            .transition(.opacity)
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
