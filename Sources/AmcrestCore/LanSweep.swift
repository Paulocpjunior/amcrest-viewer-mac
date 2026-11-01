import Foundation

/// Varredura da faixa de IP da rede local (o /24 de cada interface do Mac), pela API HTTP da câmera.
/// Complementa o ONVIF: acha NVRs e câmeras com ONVIF desligado. Só rede interna, nada de nuvem.
public enum LanSweep {

    /// Todos os IPs do /24 de `ip` (1 a 254), sem o próprio IP. Ex.: 192.168.20.5 → 192.168.20.1 ... .254.
    public static func hosts(inSubnetOf ip: String) -> [String] {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return [] }
        let base = "\(parts[0]).\(parts[1]).\(parts[2])"
        return (1...254).map { "\(base).\($0)" }.filter { $0 != ip }
    }

    /// Une as faixas de várias interfaces, sem repetir IP e mantendo a ordem.
    public static func hosts(inSubnetsOf ips: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for ip in ips {
            for h in hosts(inSubnetOf: ip) where seen.insert(h).inserted { out.append(h) }
        }
        return out
    }

    /// Portas HTTP a testar em cada IP. 80 sempre; a porta do cadastro também, se for outra.
    /// 37777 é a porta TCP própria da Dahua/Amcrest (não é HTTP) e é ignorada.
    public static func httpPorts(preferred: Int?) -> [Int] {
        var out = [80]
        if let p = preferred, p != 80, p != dahuaTCPPort, (1...65535).contains(p) { out.append(p) }
        return out
    }

    /// Porta TCP proprietária dos aparelhos Dahua/Amcrest (SDK/app oficial). Não responde HTTP.
    public static let dahuaTCPPort = 37777

    /// Aparelhos Dahua/Amcrest costumam responder 401 com `realm="Login to <S/N>"`.
    /// Devolve o S/N do realm, ou nil se o cabeçalho não tiver esse formato.
    public static func serialFromAuthHeader(_ header: String) -> String? {
        guard let r = header.range(of: "realm=\"", options: .caseInsensitive) else { return nil }
        let rest = header[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let realm = rest[..<end].trimmingCharacters(in: .whitespaces)
        let prefix = "Login to "
        guard realm.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let sn = realm.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return sn.isEmpty ? nil : sn
    }
}
