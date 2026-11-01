import SwiftUI
import AppKit
import AmcrestCore

extension Notification.Name {
    /// Pedido do menu "Procurar atualizações…" para abrir a janela de atualização.
    static let showUpdateSheet = Notification.Name("AmcrestViewer.showUpdateSheet")
}

/// Janela de atualização: versão instalada, status da verificação no GitHub e novidades.
/// Abre sozinha na primeira vez depois de uma atualização, e pelo menu / barra de status.
struct UpdateView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastSeenVersion") private var lastSeenVersion = ""
    /// Última versão vista quando a janela abriu (para listar só o que é novo).
    let previousVersion: String?

    private var news: [Release] {
        let list = AppUpdate.releasesSince(previousVersion, upTo: store.installedVersion)
        return list.isEmpty ? ReleaseNotes.all.filter { $0.version == store.installedVersion } : list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "arrow.down.app").font(.title).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Atualização do Amcrest Viewer").font(.title2.weight(.semibold))
                    Text("Instalada: \(store.installedVersion)" + (store.installedBuild.map { " (build \($0))" } ?? ""))
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack(spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.updateStatus.summary).font(.body.weight(.medium))
                        if let at = store.updateCheckedAt {
                            Text("Verificado às \(at.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if case .available = store.updateStatus {
                        Button("Ver versão nova") { NSWorkspace.shared.open(AppUpdate.projectURL) }
                    }
                    Button("Verificar agora") { Task { await store.checkForUpdates() } }
                        .disabled(store.updateStatus == .checking)
                }
                .padding(6)
            }

            Text(previousVersion.map { $0 == store.installedVersion ? "Novidades desta versão" : "Novidades desde a \($0)" }
                 ?? "Novidades desta versão")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(news) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(r.version) · \(r.title)").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(r.displayDate).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(r.changes, id: \.self) { c in
                                Text("• \(c)").font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)

            HStack {
                Spacer()
                Button("Fechar") {
                    lastSeenVersion = store.installedVersion
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { if store.updateStatus == .unknown { await store.checkForUpdates() } }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch store.updateStatus {
        case .checking: ProgressView().controlSize(.small)
        case .available: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .upToDate, .aheadOfPublished: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// Barra de status no rodapé da grade: quantas câmeras em cada estado, versão e atualização.
struct StatusBar: View {
    @EnvironmentObject private var store: CameraStore
    let onVersionTap: () -> Void
    let onStatusTap: () -> Void

    private var counts: [(CameraHealth, Int)] {
        CameraHealth.counts(store.cameras.map { store.health(of: $0) })
    }

    private func count(_ h: CameraHealth) -> Int { counts.first { $0.0 == h }?.1 ?? 0 }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onStatusTap) {
                HStack(spacing: 12) {
                    ForEach(counts.map { $0.0 }, id: \.self) { h in
                        HStack(spacing: 4) {
                            Circle().fill(Self.color(h)).frame(width: 8, height: 8)
                            Text("\(count(h)) \(h.label)")
                        }
                    }
                    if store.cameras.isEmpty { Text("Nenhuma câmera") }
                }
            }
            .buttonStyle(.plain)
            .help("Ver o status de cada câmera na Administração")
            Spacer()
            Button(action: onVersionTap) {
                HStack(spacing: 6) {
                    if case .available = store.updateStatus {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    }
                    Text("v\(store.installedVersion) · \(store.updateStatus.summary)")
                }
            }
            .buttonStyle(.plain)
            .help("Atualização e novidades")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    static func color(_ h: CameraHealth) -> Color {
        switch h {
        case .live: return .green
        case .polling: return .yellow
        case .connecting: return .gray
        case .failed: return .red
        case .unknown: return .secondary.opacity(0.5)
        }
    }
}
