import AppKit
import Vision
import AmcrestCore

/// Detecção de veículos nas imagens das câmeras, rodando no próprio Mac.
///
/// Usa o classificador de cena do Vision da Apple (`VNClassifyImageRequest`),
/// que já vem no sistema — sem baixar modelo nem usar a nuvem. Em vez de
/// localizar o veículo com um quadro, ele responde "o que há nesta imagem",
/// e nós checamos se algum rótulo de alta confiança é de veículo.
enum VehicleDetector {

    /// Há um veículo na imagem, acima de uma confiança mínima?
    /// Chamada em fila de fundo: o Vision é síncrono aqui.
    static func vehiclePresent(inCGImage cg: CGImage, minConfidence: Float = 0.3) -> Bool {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return false
        }
        let observations = (request.results ?? []).filter { $0.confidence >= minConfidence }
        return observations.contains { VehicleTaxonomy.isVehicle($0.identifier) }
    }

    /// Conveniência a partir de uma NSImage.
    static func vehiclePresent(in image: NSImage, minConfidence: Float = 0.3) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return vehiclePresent(inCGImage: cg, minConfidence: minConfidence)
    }
}

/// Junta os detectores num só passo: dado um quadro e o que procurar,
/// devolve o conjunto do que apareceu. Assim a câmera roda pessoa e veículo
/// na mesma análise, sem converter a imagem duas vezes.
enum SceneDetector {
    static func detect(
        inCGImage cg: CGImage,
        kinds: Set<DetectionKind>,
        minConfidence: Float = 0.3
    ) -> Set<DetectionKind> {
        var present: Set<DetectionKind> = []
        if kinds.contains(.person),
           PersonDetector.peopleCount(inCGImage: cg, minConfidence: minConfidence) > 0 {
            present.insert(.person)
        }
        if kinds.contains(.vehicle),
           VehicleDetector.vehiclePresent(inCGImage: cg, minConfidence: minConfidence) {
            present.insert(.vehicle)
        }
        return present
    }
}
