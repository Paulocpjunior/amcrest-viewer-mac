import Foundation

/// Recorta quadros JPEG de um fluxo MJPEG (multipart/x-mixed-replace).
///
/// Em vez de depender do `boundary` (cada firmware escreve de um jeito), procura
/// os marcadores do próprio JPEG: início `FF D8` e fim `FF D9`.
/// Recebe os bytes em pedaços, na ordem em que chegam da rede.
public struct MJPEGFrameExtractor {
    private var buffer = Data()
    /// Limite de segurança: se passar disso sem fechar um quadro, descarta.
    public let maxBufferSize: Int

    public init(maxBufferSize: Int = 8 * 1024 * 1024) {
        self.maxBufferSize = maxBufferSize
    }

    /// Acrescenta bytes e devolve os quadros JPEG completos encontrados.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []

        while true {
            guard let start = Self.find(0xFF, 0xD8, in: buffer, from: buffer.startIndex) else {
                // Nenhum início: guarda só o último byte (pode ser o FF de um FF D8 partido).
                if let last = buffer.last { buffer = Data([last]) } else { buffer.removeAll() }
                break
            }
            guard let end = Self.find(0xFF, 0xD9, in: buffer, from: start + 2) else {
                // Quadro ainda incompleto: descarta o lixo antes do início e espera mais bytes.
                if start > buffer.startIndex { buffer = Data(buffer[start...]) }
                break
            }
            frames.append(Data(buffer[start...(end + 1)]))
            buffer = Data(buffer[(end + 2)...])
        }

        if buffer.count > maxBufferSize { buffer.removeAll() }
        return frames
    }

    private static func find(_ a: UInt8, _ b: UInt8, in data: Data, from: Data.Index) -> Data.Index? {
        guard from < data.endIndex else { return nil }
        var i = from
        let last = data.endIndex - 1
        while i < last {
            if data[i] == a && data[i + 1] == b { return i }
            i += 1
        }
        return nil
    }
}
