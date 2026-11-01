import SwiftUI
import AppKit

@main
struct AmcrestViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = CameraStore()

    var body: some Scene {
        WindowGroup("Câmeras") {
            CameraGridView()
                .environmentObject(store)
                .frame(minWidth: 640, minHeight: 420)
        }

        // Uma janela por câmera, aberta com duplo clique na grade.
        WindowGroup("Câmera", for: UUID.self) { $id in
            Group {
                if let id, let camera = store.camera(id: id) {
                    CameraDetailView(camera: camera)
                } else {
                    Text("Esta câmera foi removida.")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 320, minHeight: 200)
                }
            }
            .environmentObject(store)
        }

        // Administração do hardware: cadastro, senhas, busca na rede, importação e firmware.
        Window("Administração", id: AdminWindow.id) {
            AdminView()
                .environmentObject(store)
        }
        .defaultSize(width: 980, height: 620)
        .commands { AdminCommands() }
    }
}

enum AdminWindow {
    static let id = "admin"
}

/// ⌘, abre a Administração (no lugar de "Ajustes…" do menu do app).
struct AdminCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Administração…") { openWindow(id: AdminWindow.id) }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necessário quando roda por `swift run` (sem pacote .app): vira app normal, com Dock e menu.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
