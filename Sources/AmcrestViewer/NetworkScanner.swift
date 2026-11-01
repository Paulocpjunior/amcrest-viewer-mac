import Foundation
import Darwin
import AmcrestCore

/// Procura câmeras na rede local pelo padrão aberto ONVIF (WS-Discovery).
/// Manda um Probe multicast e junta as respostas. Nada de nuvem.
@MainActor
final class NetworkScanner: ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var message: String?

    private let queue = DispatchQueue(label: "amcrest.onvif.scan", qos: .utility)

    func scan(duration: TimeInterval = 4) {
        guard !scanning else { return }
        scanning = true
        devices = []
        message = nil
        queue.async { [weak self] in
            let found = NetworkScanner.probe(duration: duration)
            Task { @MainActor in self?.finish(found) }
        }
    }

    private func finish(_ found: [DiscoveredDevice]) {
        var byHost: [String: DiscoveredDevice] = [:]
        for d in found {
            if var merged = byHost[d.host] {
                if merged.name == nil { merged.name = d.name }
                if merged.hardware == nil { merged.hardware = d.hardware }
                if merged.serial == nil { merged.serial = d.serial }
                byHost[d.host] = merged
            } else {
                byHost[d.host] = d
            }
        }
        devices = byHost.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        scanning = false
        if devices.isEmpty {
            message = "Nenhuma câmera respondeu nesta rede. Confira se o Mac está na mesma rede das câmeras e tente de novo."
        }
    }

    /// Procura na rede uma câmera com o S/N dado e devolve o aparelho (ou nil, se ninguém responder com esse S/N).
    /// Usado pelo cadastro: informar o S/N e deixar o app achar o IP local sozinho.
    func resolve(serial: String, duration: TimeInterval = 5) async -> DiscoveredDevice? {
        await withCheckedContinuation { cont in
            queue.async {
                let found = NetworkScanner.probe(duration: duration)
                cont.resume(returning: OnvifDiscovery.firstMatchingSerial(found, serial: serial))
            }
        }
    }

    /// Envia o Probe multicast e coleta respostas até `duration` segundos. Fora da main thread.
    nonisolated static func probe(duration: TimeInterval) -> [DiscoveredDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = OnvifDiscovery.multicastPort.bigEndian
        inet_pton(AF_INET, OnvifDiscovery.multicastHost, &dest.sin_addr)

        let probe = OnvifDiscovery.probeMessage(messageID: "urn:uuid:\(UUID().uuidString.lowercased())")
        let payload = Array(probe.utf8)
        _ = withUnsafePointer(to: &dest) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                payload.withUnsafeBytes { buf in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var results: [DiscoveredDevice] = []
        let deadline = Date().addingTimeInterval(duration)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            var from = sockaddr()
            var fromLen = socklen_t(MemoryLayout<sockaddr>.size)
            let n = recvfrom(fd, &buffer, buffer.count, 0, &from, &fromLen)
            if n > 0 {
                let xml = String(decoding: buffer[0..<n], as: UTF8.self)
                results.append(contentsOf: OnvifDiscovery.parseProbeMatch(xml))
            }
        }
        return results
    }
}
