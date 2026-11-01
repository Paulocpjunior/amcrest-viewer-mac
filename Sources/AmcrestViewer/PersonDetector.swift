import AppKit
import Vision

/// Detecção de pessoas nas imagens das câmeras, rodando no próprio Mac (Vision da Apple).
/// Nada vai para a nuvem. Em v1 detecta pessoa; veículo entra depois com um modelo Core ML.
enum PersonDetector {

    /// Quantas pessoas aparecem na imagem, acima de uma confiança mínima.
    /// Chamada em fila de fundo: o Vision é síncrono aqui.
    static func peopleCount(inCGImage cg: CGImage, minConfidence: Float = 0.3) -> Int {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false  // corpo inteiro: a pessoa pode aparecer longe na cena
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return 0
        }
        return (request.results ?? []).filter { $0.confidence >= minConfidence }.count
    }

    /// Conveniência a partir de uma NSImage (converte para CGImage).
    static func peopleCount(in image: NSImage, minConfidence: Float = 0.3) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        return peopleCount(inCGImage: cg, minConfidence: minConfidence)
    }
}
