import SwiftUI
import AmcrestCore

/// Janela de uma câmera: vídeo maior, PTZ, snapshot, VLC.
struct CameraDetailView: View {
    let camera: Camera
    @EnvironmentObject private var store: CameraStore
    @StateObject private var feed = CameraFeed()

    @AppStorage("detailQuality") private var qualityRaw = StreamQuality.main.rawValue
    @AppStorage("detectPeople") private var detectPeople = false
    @State private var showPTZ = true
    @State private var editing = false
    @State private var message: String?
    @State private var speed = 4.0
    @State private var preset = 1
    @State private var saveIndex = 1
    @State private var presets: [PTZPreset] = []
    @State private var showRecordings = false
    @State private var confirmSavePreset = false
    @State private var cameraPresets: [PTZPreset] = []
    @State private var newPresetName = ""

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
        .onChange(of: detectPeople) { feed.detectPeople = $0 }
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
        feed.detectPeople = detectPeople
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
                    Picker("Ir para", selection: $preset) {
                        ForEach(presets) { p in Text("\(p.index). \(p.name)").tag(p.index) }
                    }
                    .labelsHidden()
                    Button("Ir") { run { try await client.gotoPreset(preset) } }
                }
                Divider()
                Text("Salvar posição atual").font(.caption)
                HStack {
                    Stepper("Nº \(saveIndex)", value: $saveIndex, in: 1...255)
                }
                TextField("Nome (ex.: Portão)", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                Button("Salvar aqui") { confirmSavePreset = true }
                    .help("Grava a posição atual da câmera neste número, com o nome digitado")
            }
            .confirmationDialog("Salvar a posição atual no preset \(saveIndex)?",
                                isPresented: $confirmSavePreset) {
                Button("Salvar") {
                    let n = saveIndex
                    let name = newPresetName
                    run {
                        try await client.setPreset(n)
                        PresetNames.set(name, index: n, camera: current)
                        newPresetName = ""
                        preset = n
                        loadPresets()
                    }
                }
            } message: { Text("Se já houver uma posição gravada neste número, ela será substituída.") }
            Text("Segure o botão para mover. Câmeras fixas (sem PTZ) ignoram estes comandos.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private func loadPresets() {
        let c = client
        let cam = current
        Task {
            // Câmeras sem PTZ ou firmware antigo não respondem: valem só os nomes do app.
            if let list = try? await c.presets() { cameraPresets = list }
            presets = PTZPreset.merge(camera: cameraPresets, local: PresetNames.all(camera: cam))
            if let first = presets.first, !presets.contains(where: { $0.index == preset }) { preset = first.index }
            // Sugere o próximo número livre para salvar.
            let used = Set(presets.map(\.index))
            saveIndex = (1...255).first { !used.contains($0) } ?? 1
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

/// Nomes de preset dados no app, por câmera (a API HTTP não grava nome de preset de forma uniforme).
enum PresetNames {
    private static func key(_ cam: Camera) -> String { "presetNames.\(cam.id.uuidString)" }

    static func all(camera: Camera) -> [Int: String] {
        let raw = UserDefaults.standard.dictionary(forKey: key(camera)) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    static func set(_ name: String, index: Int, camera: Camera) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var raw = UserDefaults.standard.dictionary(forKey: key(camera)) as? [String: String] ?? [:]
        if trimmed.isEmpty { raw.removeValue(forKey: String(index)) } else { raw[String(index)] = trimmed }
        UserDefaults.standard.set(raw, forKey: key(camera))
    }
}
