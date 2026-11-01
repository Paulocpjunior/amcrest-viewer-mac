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
            message = "Nenhuma câmera respondeu nesta rede. Confira se o Mac está na mesma rede das câmeras. Se houver VPN ligada, desligue e tente de novo."
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

    /// Interfaces IPv4 físicas e ativas (en*, bridge*), ignorando loopback, link-local e VPN
    /// (utun/ppp/ipsec). É a lista por onde o Probe precisa sair: numa máquina com VPN, a rota
    /// padrão pode ir pela VPN e o multicast nunca chega às câmeras da LAN.
    nonisolated static func activeIPv4Interfaces() -> [(name: String, ip: String, index: UInt32)] {
        var out: [(String, String, UInt32)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var ptr = ifap
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
            out.append((name, ip, if_nametoindex(name)))
        }
        return out
    }

    /// Envia o Probe por CADA interface física ativa e coleta respostas até `duration` segundos.
    /// Fora da main thread.
    nonisolated static func probe(duration: TimeInterval) -> [DiscoveredDevice] {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = OnvifDiscovery.multicastPort.bigEndian
        inet_pton(AF_INET, OnvifDiscovery.multicastHost, &dest.sin_addr)

        let payload = Array(OnvifDiscovery.probeMessage(messageID: "urn:uuid:\(UUID().uuidString.lowercased())").utf8)

        // Um socket por interface, cada um amarrado à sua interface. Sem interface detectada,
        // cai para um socket padrão (comportamento antigo).
        let interfaces = activeIPv4Interfaces()
        var sockets: [Int32] = []
        if interfaces.isEmpty {
            if let fd = makeProbeSocket(interface: nil, dest: &dest, payload: payload) { sockets.append(fd) }
        } else {
            for itf in interfaces {
                if let fd = makeProbeSocket(interface: itf, dest: &dest, payload: payload) { sockets.append(fd) }
            }
        }
        guard !sockets.isEmpty else { return [] }
        defer { sockets.forEach { close($0) } }

        var results: [DiscoveredDevice] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            for fd in sockets {
                var from = sockaddr()
                var fromLen = socklen_t(MemoryLayout<sockaddr>.size)
                let n = recvfrom(fd, &buffer, buffer.count, 0, &from, &fromLen)
                if n > 0 {
                    let xml = String(decoding: buffer[0..<n], as: UTF8.self)
                    results.append(contentsOf: OnvifDiscovery.parseProbeMatch(xml))
                }
            }
        }
        return results
    }

    /// Cria um socket UDP já configurado e dispara o Probe. `interface` nil = rota padrão.
    /// Amarra a saída à interface (IP_BOUND_IF + IP_MULTICAST_IF) para a VPN não roubar o multicast.
    private nonisolated static func makeProbeSocket(
        interface: (name: String, ip: String, index: UInt32)?,
        dest: inout sockaddr_in, payload: [UInt8]
    ) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }

        // 0,3s por leitura, para revezar entre as interfaces sem travar.
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        if let itf = interface {
            var idx = itf.index
            setsockopt(fd, Int32(IPPROTO_IP), IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
            var ifaddr = in_addr()
            if inet_pton(AF_INET, itf.ip, &ifaddr) == 1 {
                setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_IF, &ifaddr, socklen_t(MemoryLayout<in_addr>.size))
            }
        }

        let sent = withUnsafePointer(to: &dest) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                payload.withUnsafeBytes { buf in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { close(fd); return nil }
        return fd
    }
}
