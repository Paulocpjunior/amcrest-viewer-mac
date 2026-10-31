import SwiftUI
import AmcrestCore

/// Janela de uma câmera: vídeo maior, PTZ, snapshot, VLC.
struct CameraDetailView: View {
    let camera: Camera
    @EnvironmentObject private var store: CameraStore
    @StateObject private var feed = CameraFeed()

    @AppStorage("detailQuality") private var qualityRaw = StreamQuality.main.rawValue
    @State private var showPTZ = true
    @State private var editing = false
    @State private var message: String?
    @State private var speed = 4.0
    @State private var preset = 1
    @State private var presets: [PTZPreset] = []
    @State private var showRecordings = false
    @State private var confirmSavePreset = false

    private var quality: StreamQuality { StreamQuality(rawValue: qualityRaw) ?? .main }
    /// Sempre a versão atual do cadastro (pode ter sido editada nesta janela).
    private var current: Camera { store.camera(id: camera.id) ?? camera }
    private var client: AmcrestClient { AmcrestClient(camera: current, password: store.password(for: current)) }

    var body: some View {
        HStack(spacing: 0) {
            FeedView(feed: feed, camera: current)
                .frame(minWidth: 480, minHeight: 270)
            if showPTZ {
                Divider()
                ptzPanel.frame(width: 200)
            }
        }
        .navigationTitle(current.name)
        .toolbar {
            ToolbarItemGroup {
                Picker("Qualidade", selection: $qualityRaw) {
                    Text("Alta").tag(StreamQuality.main.rawValue)
                    Text("Leve").tag(StreamQuality.sub.rawValue)
                }
                .pickerStyle(.segmented)
                .help("Alta = fluxo principal. Se a câmera não der MJPEG nele, o app usa snapshots.")

                Button { takeSnapshot() } label: { Label("Snapshot", systemImage: "camera") }
                    .help("Salvar foto em Imagens/Amcrest")
                Button {
                    message = ExternalActions.openInVLC(current, password: store.password(for: current))
                } label: { Label("VLC", systemImage: "play.rectangle") }
                    .help("Abrir o RTSP principal no VLC (alta qualidade, com áudio)")
                Button { showRecordings = true } label: { Label("Gravações", systemImage: "sdcard") }
                    .help("Ver e baixar os vídeos gravados no cartão microSD")
                Toggle(isOn: $showPTZ) { Label("PTZ", systemImage: "dpad") }
                    .help("Mostrar controles de movimento")
                Button { editing = true } label: { Label("Editar", systemImage: "slider.horizontal.3") }
            }
        }
        .onAppear { start(); loadPresets() }
        .onDisappear { feed.stop() }
        .onChange(of: qualityRaw) { _ in start() }
        .onChange(of: store.revision) { _ in start(); loadPresets() }
        .sheet(isPresented: $showRecordings) {
            RecordingsView(camera: current, password: store.password(for: current))
        }
        .sheet(isPresented: $editing) {
            if let current = store.camera(id: camera.id) {
                CameraEditorView(camera: current, isNew: false).environmentObject(store)
            }
        }
        .alert("Aviso", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    private func start() {
        feed.start(camera: current, password: store.password(for: current), quality: quality)
    }

    // MARK: - PTZ

    private var ptzPanel: some View {
        VStack(spacing: 14) {
            Text("Movimento").font(.headline)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ptzButton(.leftUp, "arrow.up.left")
                    ptzButton(.up, "arrow.up")
                    ptzButton(.rightUp, "arrow.up.right")
                }
                GridRow {
                    ptzButton(.left, "arrow.left")
                    Color.clear.frame(width: 44, height: 44)
                    ptzButton(.right, "arrow.right")
                }
                GridRow {
                    ptzButton(.leftDown, "arrow.down.left")
                    ptzButton(.down, "arrow.down")
                    ptzButton(.rightDown, "arrow.down.right")
                }
            }
            HStack {
                ptzButton(.zoomOut, "minus.magnifyingglass")
                ptzButton(.zoomIn, "plus.magnifyingglass")
            }
            VStack(alignment: .leading) {
                Text("Velocidade: \(Int(speed))").font(.caption)
                Slider(value: $speed, in: 1...8, step: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Presets").font(.caption)
                if !presets.isEmpty {
                    Picker("Preset", selection: $preset) {
                        ForEach(presets) { p in Text("\(p.index). \(p.name)").tag(p.index) }
                    }
                    .labelsHidden()
                } else {
                    Stepper("Preset \(preset)", value: $preset, in: 1...255)
                }
                HStack {
                    Button("Ir") { run { try await client.gotoPreset(preset) } }
                    Button("Salvar aqui") { confirmSavePreset = true }
                        .help("Grava a posição atual no preset escolhido")
                }
            }
            .confirmationDialog("Salvar a posição atual no preset \(preset)?",
                                isPresented: $confirmSavePreset) {
                Button("Salvar") {
                    let n = preset
                    run {
                        try await client.setPreset(n)
                        loadPresets()
                    }
                }
            } message: { Text("O que estava gravado neste preset será substituído.") }
            Text("Segure o botão para mover. Câmeras fixas (sem PTZ) ignoram estes comandos.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private func loadPresets() {
        let c = client
        Task {
            // Câmeras sem PTZ ou firmware antigo não respondem: fica o seletor numérico.
            if let list = try? await c.presets(), !list.isEmpty {
                presets = list
                if !list.contains(where: { $0.index == preset }) { preset = list[0].index }
            }
        }
    }

    private func ptzButton(_ cmd: PTZCommand, _ symbol: String) -> some View {
        PressHoldButton(systemImage: symbol) { pressed in
            let s = Int(speed)
            run { try await client.ptz(cmd, start: pressed, speed: s) }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch {
                message = CameraError.friendly(error, camera: current)
            }
        }
    }

    private func takeSnapshot() {
        let cam = current
        Task {
            do {
                let data = try await client.snapshot()
                _ = try ExternalActions.saveSnapshot(data, camera: cam)
            } catch {
                message = CameraError.friendly(error, camera: cam)
            }
        }
    }
}

/// Botão que avisa quando é pressionado e quando é solto (para PTZ: start/stop).
struct PressHoldButton: View {
    let systemImage: String
    let onChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(pressed ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onChange(true) }
                    }
                    .onEnded { _ in
                        pressed = false
                        onChange(false)
                    }
            )
    }
}
