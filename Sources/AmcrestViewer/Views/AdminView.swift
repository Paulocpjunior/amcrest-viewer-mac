import SwiftUI
import UniformTypeIdentifiers
import AmcrestCore

/// Seções da janela de Administração.
enum AdminSection: String, CaseIterable, Identifiable {
    case cameras, add, credentials, hardware

    var id: Self { self }

    var title: String {
        switch self {
        case .cameras: return "Câmeras"
        case .add: return "Adicionar câmeras"
        case .credentials: return "Usuário e senha"
        case .hardware: return "Hardware e firmware"
        }
    }

    var symbol: String {
        switch self {
        case .cameras: return "video"
        case .add: return "plus.circle"
        case .credentials: return "key"
        case .hardware: return "cpu"
        }
    }
}

/// Pedido para abrir o cadastro (nova câmera, por S/N, ou edição).
struct EditorRequest: Identifiable {
    let id = UUID()
    let camera: Camera
    let isNew: Bool
    var bySerial = false
}

/// Janela de Administração do hardware: tudo que é cadastro e configuração das câmeras
/// sai da grade (que fica só para assistir) e mora aqui, organizado por seção.
struct AdminView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("adminSection") private var sectionRaw = AdminSection.cameras.rawValue

    @State private var editor: EditorRequest?
    @State private var scanning = false
    @State private var showImporter = false
    @State private var importReport: ImportReport?
    @State private var confirmRemove: [Camera] = []

    private var section: Binding<AdminSection?> {
        Binding(get: { AdminSection(rawValue: sectionRaw) ?? .cameras },
                set: { sectionRaw = ($0 ?? .cameras).rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(AdminSection.allCases, selection: section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Administração")
        .frame(minWidth: 820, minHeight: 500)
        .onAppear { store.adminVisible = true }
        .onDisappear { store.adminVisible = false }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text]) { result in
            if case .success(let url) = result { importReport = store.importTXT(from: url) }
        }
        .sheet(item: $importReport) { ImportReportView(report: $0).environmentObject(store) }
        .sheet(item: $editor) { req in
            CameraEditorView(camera: req.camera, isNew: req.isNew, bySerial: req.bySerial)
                .environmentObject(store)
        }
        .sheet(isPresented: $scanning) { NetworkScanView().environmentObject(store) }
        .alert(removeTitle, isPresented: Binding(
            get: { !confirmRemove.isEmpty }, set: { if !$0 { confirmRemove = [] } })
        ) {
            Button("Remover", role: .destructive) {
                for cam in confirmRemove { store.remove(cam) }
                confirmRemove = []
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As câmeras e as senhas salvas no Keychain serão apagadas deste Mac.")
        }
        .alert("Atenção", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var removeTitle: String {
        confirmRemove.count == 1 ? "Remover \(confirmRemove[0].name)?" : "Remover \(confirmRemove.count) câmeras?"
    }

    @ViewBuilder
    private var detail: some View {
        switch AdminSection(rawValue: sectionRaw) ?? .cameras {
        case .cameras:
            AdminCamerasPane(
                onAdd: { editor = EditorRequest(camera: Camera(name: "", host: ""), isNew: true) },
                onEdit: { editor = EditorRequest(camera: $0, isNew: false) },
                onRemove: { confirmRemove = $0 },
                onOpen: { openWindow(value: $0.id) },
                onGoToAdd: { sectionRaw = AdminSection.add.rawValue }
            )
        case .add:
            AdminAddPane(
                onScan: { scanning = true },
                onByIP: { editor = EditorRequest(camera: Camera(name: "", host: ""), isNew: true) },
                onBySerial: { editor = EditorRequest(camera: Camera(name: "", host: ""), isNew: true, bySerial: true) },
                onImport: { showImporter = true }
            )
        case .credentials:
            AdminCredentialsPane()
        case .hardware:
            AdminHardwarePane()
        }
    }
}

// MARK: - Câmeras

/// Lista de todas as câmeras com busca, situação da senha e ações.
struct AdminCamerasPane: View {
    @EnvironmentObject private var store: CameraStore
    let onAdd: () -> Void
    let onEdit: (Camera) -> Void
    let onRemove: ([Camera]) -> Void
    let onOpen: (Camera) -> Void
    let onGoToAdd: () -> Void

    @State private var query = ""
    @State private var selection: Set<Camera.ID> = []

    private var visible: [Camera] { CameraAdmin.filter(store.cameras, query: query) }
    private var selected: [Camera] { store.cameras.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdminHeader(title: "Câmeras",
                        subtitle: "\(store.cameras.count) cadastrada(s). Duplo clique para editar.")

            HStack {
                TextField("Buscar por nome, IP ou S/N", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                Button { onAdd() } label: { Label("Adicionar", systemImage: "plus") }
                Button { if let c = selected.first { onEdit(c) } } label: { Label("Editar", systemImage: "pencil") }
                    .disabled(selected.count != 1)
                Button { if let c = selected.first { onOpen(c) } } label: { Label("Abrir", systemImage: "macwindow") }
                    .disabled(selected.count != 1)
                Button(role: .destructive) { onRemove(selected) } label: { Label("Remover", systemImage: "trash") }
                    .disabled(selected.isEmpty)
            }

            if store.cameras.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "video.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Nenhuma câmera cadastrada.").foregroundStyle(.secondary)
                    Button("Adicionar câmeras…") { onGoToAdd() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(visible, selection: $selection) {
                    TableColumn("Nome") { cam in
                        Text(cam.name)
                    }
                    TableColumn("Endereço") { cam in
                        Text(CameraAdmin.connectionLabel(cam)).foregroundStyle(cam.host.isEmpty ? Color.orange : Color.primary)
                    }
                    TableColumn("S/N") { cam in
                        Text(cam.serialNumber ?? "—").foregroundStyle(.secondary)
                    }
                    TableColumn("Usuário") { cam in
                        Text(cam.username)
                    }
                    TableColumn("Senha") { cam in
                        if store.hasPassword(cam) {
                            Label("no Keychain", systemImage: "lock.fill").foregroundStyle(.green)
                        } else {
                            Label("falta", systemImage: "lock.open").foregroundStyle(.orange)
                        }
                    }
                    .width(110)
                }
                .contextMenu(forSelectionType: Camera.ID.self) { ids in
                    let cams = store.cameras.filter { ids.contains($0.id) }
                    if cams.count == 1, let cam = cams.first {
                        Button("Editar…") { onEdit(cam) }
                        Button("Abrir em janela") { onOpen(cam) }
                        Divider()
                    }
                    if !cams.isEmpty {
                        Button("Remover…", role: .destructive) { onRemove(cams) }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let cam = store.cameras.first(where: { ids.contains($0.id) }) { onEdit(cam) }
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Adicionar

/// As formas de cadastrar câmera, cada uma com a explicação de quando usar.
struct AdminAddPane: View {
    let onScan: () -> Void
    let onByIP: () -> Void
    let onBySerial: () -> Void
    let onImport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AdminHeader(title: "Adicionar câmeras", subtitle: "Escolha como cadastrar. Nada vai para a nuvem.")
                AdminActionCard(symbol: "dot.radiowaves.left.and.right",
                                title: "Procurar na rede",
                                text: "Acha as câmeras ligadas na mesma rede do Mac (ONVIF) e adiciona as marcadas num clique.",
                                button: "Procurar…", action: onScan)
                AdminActionCard(symbol: "number",
                                title: "Por número de série (S/N)",
                                text: "Informe o S/N da etiqueta da câmera. O app procura a câmera na rede e preenche o IP.",
                                button: "Adicionar por S/N…", action: onBySerial)
                AdminActionCard(symbol: "network",
                                title: "Por endereço IP",
                                text: "Para câmeras com IP fixo, nome de rede, porta diferente ou canal de NVR.",
                                button: "Adicionar por IP…", action: onByIP)
                AdminActionCard(symbol: "doc.text",
                                title: "Importar lista .txt",
                                text: "Uma câmera por linha (ex.: Garagem 192.168.1.10). Câmeras já cadastradas não duplicam.",
                                button: "Importar…", action: onImport)
            }
            .padding(20)
        }
    }
}

struct AdminActionCard: View {
    let symbol: String
    let title: String
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(text).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(button, action: action)
            }
            .padding(6)
        }
    }
}

// MARK: - Usuário e senha

/// Aplica o mesmo usuário e senha a várias câmeras de uma vez (senha vai para o Keychain).
struct AdminCredentialsPane: View {
    @EnvironmentObject private var store: CameraStore
    @State private var selection: Set<Camera.ID> = []
    @State private var username = "admin"
    @State private var password = ""
    @State private var done: String?

    private var missing: [Camera] { store.cameras.filter { !store.hasPassword($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdminHeader(title: "Usuário e senha",
                        subtitle: "As senhas ficam só no Keychain deste Mac. \(missing.count) câmera(s) sem senha.")

            HStack {
                Button("Marcar sem senha") { selection = Set(missing.map(\.id)) }
                    .disabled(missing.isEmpty)
                Button("Marcar todas") { selection = Set(store.cameras.map(\.id)) }
                Button("Limpar") { selection = [] }
                Spacer()
                Text("\(selection.count) marcada(s)").font(.caption).foregroundStyle(.secondary)
            }

            List(store.cameras, selection: $selection) { cam in
                HStack {
                    Text(cam.name)
                    Text(CameraAdmin.connectionLabel(cam)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(cam.username).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: store.hasPassword(cam) ? "lock.fill" : "lock.open")
                        .foregroundStyle(store.hasPassword(cam) ? .green : .orange)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            GroupBox {
                HStack {
                    TextField("Usuário", text: $username).frame(width: 140)
                    SecureField("Senha", text: $password).frame(width: 200)
                    Button("Aplicar às marcadas") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection.isEmpty || password.isEmpty)
                    Spacer()
                }
                .padding(4)
            }
            if let done {
                Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(20)
    }

    private func apply() {
        let targets = store.cameras.filter { selection.contains($0.id) }
        store.applyCredentials(to: targets, username: username.trimmingCharacters(in: .whitespaces), password: password)
        password = ""
        done = "Senha salva em \(targets.count) câmera(s). As câmeras reconectam sozinhas."
    }
}

// MARK: - Hardware e firmware

/// Lê da própria câmera modelo, firmware, S/N e hardware. Atualização de firmware vem depois.
struct AdminHardwarePane: View {
    @EnvironmentObject private var store: CameraStore

    enum ReadState: Sendable {
        case loading
        case loaded(DeviceInfo)
        case failed(String)
    }

    @State private var states: [UUID: ReadState] = [:]
    @State private var work: Task<Void, Never>?

    private var reading: Bool { states.values.contains { if case .loading = $0 { return true } else { return false } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdminHeader(title: "Hardware e firmware",
                        subtitle: "Dados lidos direto de cada câmera, na rede local.")
            HStack {
                Button { readAll() } label: { Label("Ler dados das câmeras", systemImage: "arrow.clockwise") }
                    .disabled(store.cameras.isEmpty || reading)
                if reading { ProgressView().controlSize(.small) }
                Spacer()
            }

            List(store.cameras) { cam in
                row(cam)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            GroupBox {
                Label("Atualização de firmware pelo app: em breve. Por enquanto o app mostra a versão instalada em cada câmera.",
                      systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
        }
        .padding(20)
        .onDisappear { work?.cancel() }
    }

    @ViewBuilder
    private func row(_ cam: Camera) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cam.name).font(.body.weight(.medium))
                Text(CameraAdmin.connectionLabel(cam)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Ler") { read([cam]) }
                    .controlSize(.small)
                    .disabled(isLoading(cam))
            }
            switch states[cam.id] {
            case .none:
                Text("Ainda não lido.").font(.caption).foregroundStyle(.secondary)
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let info):
                HStack(spacing: 16) {
                    field("Modelo", info.model)
                    field("Firmware", info.firmware.map { v in info.firmwareBuild.map { "\(v) (\($0))" } ?? v })
                    field("S/N", info.serial)
                    field("Hardware", info.hardware)
                    if let sn = info.serial, (cam.serialNumber ?? "").isEmpty {
                        Button("Guardar S/N no cadastro") {
                            var c = cam
                            c.serialNumber = sn
                            store.save(c, password: nil)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func field(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "—").font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func isLoading(_ cam: Camera) -> Bool {
        if case .loading? = states[cam.id] { return true }
        return false
    }

    private func readAll() { read(store.cameras) }

    private func read(_ cams: [Camera]) {
        let jobs = cams.filter { !$0.host.isEmpty }
        for cam in cams where cam.host.isEmpty {
            states[cam.id] = .failed("Sem endereço. Edite a câmera ou use Procurar na rede.")
        }
        for cam in jobs { states[cam.id] = .loading }
        let pairs = jobs.map { ($0, store.password(for: $0)) }
        work = Task {
            await withTaskGroup(of: (UUID, ReadState).self) { group in
                for (cam, pwd) in pairs {
                    group.addTask {
                        do {
                            let info = try await AmcrestClient(camera: cam, password: pwd).deviceInfo()
                            return (cam.id, .loaded(info))
                        } catch {
                            return (cam.id, .failed(CameraError.friendly(error, camera: cam)))
                        }
                    }
                }
                for await (id, state) in group {
                    states[id] = state
                }
            }
        }
    }
}

// MARK: - Comum

struct AdminHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}
