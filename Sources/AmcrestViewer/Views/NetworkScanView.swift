import SwiftUI
import AmcrestCore

/// "Procurar câmeras na rede": acha câmeras pelo padrão aberto ONVIF (WS-Discovery),
/// lista o que respondeu com nome, IP e S/N, e adiciona as marcadas num clique.
/// Nada vai para a nuvem: as câmeras respondem a um broadcast na própria rede.
struct NetworkScanView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = NetworkScanner()
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .onAppear { if scanner.devices.isEmpty { scanner.scan() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Procurar câmeras na rede").font(.headline)
                Text("Busca pela própria rede (ONVIF). Nada vai para a nuvem.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                selected = []
                scanner.scan()
            } label: {
                if scanner.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Procurar de novo", systemImage: "arrow.clockwise")
                }
            }
            .disabled(scanner.scanning)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if scanner.scanning && scanner.devices.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Procurando na rede…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scanner.devices.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 36)).foregroundStyle(.secondary)
                Text(scanner.message ?? "Nenhuma câmera encontrada.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(scanner.devices) { device in
                    row(device)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ device: DiscoveredDevice) -> some View {
        let already = store.cameras.contains { $0.host == device.host }
        return HStack(spacing: 10) {
            Image(systemName: selected.contains(device.host) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected.contains(device.host) ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(device.host).font(.caption).foregroundStyle(.secondary)
                    if let sn = device.serial {
                        Text("S/N \(sn)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if already {
                Text("já cadastrada").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !already else { return }
            if selected.contains(device.host) { selected.remove(device.host) }
            else { selected.insert(device.host) }
        }
        .opacity(already ? 0.5 : 1)
    }

    private var footer: some View {
        HStack {
            Text("\(selected.count) selecionada(s)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Fechar") { dismiss() }
            Button("Adicionar selecionadas") { addSelected() }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
        }
        .padding()
    }

    private func addSelected() {
        for device in scanner.devices where selected.contains(device.host) {
            let camera = Camera(name: device.displayName, host: device.host, serialNumber: device.serial)
            store.save(camera, password: nil)
        }
        dismiss()
    }
}
