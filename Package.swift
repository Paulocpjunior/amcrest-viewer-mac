// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AmcrestViewer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AmcrestViewer", targets: ["AmcrestViewer"]),
        .library(name: "AmcrestCore", targets: ["AmcrestCore"]),
    ],
    targets: [
        // Lógica pura (só Foundation): modelos, leitura do .txt, URLs da API, extração de quadros MJPEG.
        .target(name: "AmcrestCore"),
        // App SwiftUI: telas, rede, Keychain.
        .executableTarget(name: "AmcrestViewer", dependencies: ["AmcrestCore"]),
        .testTarget(name: "AmcrestCoreTests", dependencies: ["AmcrestCore"]),
    ]
)
