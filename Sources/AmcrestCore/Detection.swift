import Foundation

/// O que a IA procura nas imagens das câmeras.
public enum DetectionKind: String, Codable, Sendable, CaseIterable {
    case person
    case vehicle

    public var label: String {
        switch self {
        case .person: return "Pessoa"
        case .vehicle: return "Veículo"
        }
    }
}

/// Lógica pura que controla a detecção por IA, sem depender do Vision nem de rede.
///
/// Resolve três coisas, todas com o tempo injetado (testável):
/// 1. **Throttle:** não analisar todo quadro, só a cada `analysisInterval` segundos.
/// 2. **Hold:** depois de detectar, manter "presente" por `holdWindow` segundos,
///    para o selo não piscar quando um quadro falha a detecção.
/// 3. **Cooldown de evento:** avisar o usuário (log, notificação) no máximo uma vez
///    a cada `eventCooldown` segundos, para uma pessoa parada não gerar enxurrada.
public struct DetectionGate: Sendable {
    public let analysisInterval: TimeInterval
    public let holdWindow: TimeInterval
    public let eventCooldown: TimeInterval

    private var lastAnalysis: Date?
    private var lastPositive: Date?
    private var lastEvent: Date?

    public init(
        analysisInterval: TimeInterval = 1.0,
        holdWindow: TimeInterval = 3.0,
        eventCooldown: TimeInterval = 15.0
    ) {
        self.analysisInterval = max(0, analysisInterval)
        self.holdWindow = max(0, holdWindow)
        self.eventCooldown = max(0, eventCooldown)
    }

    /// Resultado de registrar uma análise.
    public struct Outcome: Equatable, Sendable {
        /// Há algo presente agora, considerando a janela de hold (para o selo na tela).
        public var isPresent: Bool
        /// Esta análise deve gerar um aviso ao usuário (respeitando o cooldown).
        public var raisedEvent: Bool
    }

    /// Passou tempo suficiente desde a última análise para rodar o detector de novo?
    public mutating func shouldAnalyze(now: Date) -> Bool {
        if let last = lastAnalysis, now.timeIntervalSince(last) < analysisInterval {
            return false
        }
        lastAnalysis = now
        return true
    }

    /// Registra o resultado de uma análise (detectou ou não) e decide selo e evento.
    public mutating func record(detected: Bool, now: Date) -> Outcome {
        if detected { lastPositive = now }

        let present: Bool
        if let last = lastPositive {
            present = now.timeIntervalSince(last) <= holdWindow
        } else {
            present = false
        }

        var raised = false
        if detected {
            if let last = lastEvent {
                if now.timeIntervalSince(last) >= eventCooldown {
                    raised = true
                    lastEvent = now
                }
            } else {
                raised = true
                lastEvent = now
            }
        }

        return Outcome(isPresent: present, raisedEvent: raised)
    }
}

/// Decide se um rótulo de classificação do Vision corresponde a um veículo.
///
/// Lógica pura (sem Vision), para poder ser testada. O `VNClassifyImageRequest`
/// devolve identificadores como `car`, `sports_car`, `wheeled_vehicle`,
/// `pickup_truck`. Comparamos por *token* (partes separadas por `_` ou espaço),
/// e não por substring, para não confundir, por exemplo, `scarf` com `car`.
public enum VehicleTaxonomy {
    /// Tokens que indicam um veículo a motor (carro, caminhão, ônibus, moto, van…).
    /// Bicicleta fica de fora de propósito: o foco é veículo motorizado.
    public static let tokens: Set<String> = [
        "car", "cars",
        "truck", "trucks",
        "bus", "buses",
        "van", "vans",
        "vehicle", "vehicles",
        "motorcycle", "motorbike", "moped",
        "suv", "jeep", "pickup",
        "taxi", "cab",
        "sedan", "hatchback", "convertible", "coupe", "minivan",
        "ambulance",
    ]

    /// `true` se o identificador tiver algum token de veículo.
    public static func isVehicle(_ identifier: String) -> Bool {
        let parts = identifier
            .lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
            .map(String.init)
        return parts.contains { tokens.contains($0) }
    }
}
