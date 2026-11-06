import Foundation

// Note 89 : commandes (liste fermée, par marque) et analyse des sorties du test de câble. Tout
// est pur : testé sur des textes fixes dans NetScopeSelfTest, sans réseau.

/// Commandes envoyées au switch : construites ici seulement, jamais saisies par l'utilisateur.
public enum CableTestCommands {
    /// Étapes d'un test : chaque étape est une connexion SSH qui reçoit ses lignes sur l'entrée ;
    /// `waitSeconds` s'écoule entre deux étapes (Cisco : le test tourne en arrière-plan).
    public struct Plan: Equatable, Sendable {
        public var steps: [[String]]
        public var waitSeconds: Int

        public init(steps: [[String]], waitSeconds: Int) {
            self.steps = steps
            self.waitSeconds = waitSeconds
        }
    }

    /// Nom de port accepté pour la marque (strict : lettres, chiffres et « / » attendus seulement).
    public static func isValidPort(_ port: String, vendor: CableTestVendor) -> Bool {
        guard !port.isEmpty, port.count <= 32, port.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        let pattern: String
        switch vendor {
        case .cisco:
            pattern = "^(?:Gi|Fa|Te|Tw|Fi|Et|Eth|GigabitEthernet|FastEthernet|TenGigabitEthernet|TwoGigabitEthernet|FiveGigabitEthernet|Ethernet)\\d{1,2}(?:/\\d{1,2}){1,3}$"
        case .aruba:
            pattern = "^(?:[A-Z]?\\d{1,3}|\\d{1,2}/[A-Z]?\\d{1,3}|\\d{1,2}/\\d{1,2}/\\d{1,3})$"
        case .fortiSwitch:
            pattern = "^port\\d{1,3}$"
        }
        return port.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// AOS-CX (« 1/1/12 ») plutôt qu'AOS-S (« 12 », « A3 », « 1/12 »).
    static func isAOSCX(_ port: String) -> Bool {
        port.range(of: "^\\d{1,2}/\\d{1,2}/\\d{1,3}$", options: .regularExpression) != nil
    }

    /// Plan du test ; nil si le port est refusé.
    public static func plan(vendor: CableTestVendor, port: String) -> Plan? {
        guard isValidPort(port, vendor: vendor) else { return nil }
        switch vendor {
        case .cisco:
            return Plan(steps: [["terminal length 0", "test cable-diagnostics tdr interface \(port)", "exit"],
                                ["terminal length 0", "show cable-diagnostics tdr interface \(port)", "exit"]],
                        waitSeconds: 8)
        case .aruba:
            if isAOSCX(port) {
                return Plan(steps: [["no page", "diagnostics", "diag cable-diagnostic \(port)", "exit"]], waitSeconds: 0)
            }
            // AOS-S demande « Continue (y/n)? » : la réponse suit sur l'entrée.
            return Plan(steps: [["no page", "virtual-cable-test ethernet \(port)", "y"]], waitSeconds: 0)
        case .fortiSwitch:
            return Plan(steps: [["diagnose switch physical-ports cable-diag \(port)"]], waitSeconds: 0)
        }
    }

    /// Débuts de commande permis (toute autre ligne bloque l'envoi).
    public static let allowedPrefixes = ["terminal length 0", "no page", "exit", "y", "diagnostics",
                                         "test cable-diagnostics tdr interface ", "show cable-diagnostics tdr interface ",
                                         "virtual-cable-test ethernet ", "diag cable-diagnostic ",
                                         "diagnose switch physical-ports cable-diag "]

    /// Chaque ligne du plan est dans la liste fermée.
    public static func isAllowed(_ plan: Plan) -> Bool {
        plan.steps.allSatisfy { step in
            step.allSatisfy { line in
                allowedPrefixes.contains { $0.hasSuffix(" ") ? line.hasPrefix($0) : line == $0 }
                    && !line.contains(";") && !line.contains("|") && !line.contains("\n")
            }
        }
    }

    /// Requête de la FortiGate (GET : diagnostic de câble d'un port de FortiSwitch géré).
    public static let fortiGatePath = "/api/v2/monitor/switch-controller/managed-switch/cable-status"

    public static func fortiGateQuery(switchID: String, port: String, vdom: String = "") -> [URLQueryItem] {
        var items = [URLQueryItem(name: "mkey", value: switchID), URLQueryItem(name: "port", value: port)]
        if !vdom.isEmpty { items.append(URLQueryItem(name: "vdom", value: vdom)) }
        return items
    }
}

/// Erreur de sortie : le switch a refusé ou n'a pas fini.
public struct CableTestOutputError: Error, Equatable, Sendable {
    public var message: String
}

/// Analyse des sorties.
public enum CableTestParser {
    /// Paire : « A »…« D », « 1 »…« 4 », « 1-2 », « 3-6 », « 4-5 », « 7-8 ».
    public static func pairNumber(_ token: String) -> Int? {
        switch token.uppercased().trimmingCharacters(in: .whitespaces) {
        case "A", "1", "1-2", "1,2": return 1
        case "B", "2", "3-6", "3,6": return 2
        case "C", "3", "4-5", "4,5": return 3
        case "D", "4", "7-8", "7,8": return 4
        default: return nil
        }
    }

    /// Message d'erreur reconnu dans une sortie (commande refusée, test en cours…).
    static func refusal(in text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("tdr test is in progress") || lower.contains("test is in progress") {
            return "le switch n’a pas fini le test, relancez-le dans quelques secondes."
        }
        if lower.contains("not supported") && !lower.contains("pair") {
            return "ce port ne permet pas le test de câble (fibre, module SFP ou modèle sans TDR)."
        }
        for marker in ["% invalid input", "invalid input detected", "% unrecognized command", "command fail", "unknown action",
                       "invalid command", "command not found", "% incomplete command"] where lower.contains(marker) {
            return "commande refusée par le switch."
        }
        return nil
    }

    private static func matches(_ pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// Cisco : « show cable-diagnostics tdr interface … ».
    public static func cisco(_ text: String) -> Result<[CablePairResult], CableTestOutputError> {
        if let refusal = refusal(in: text) { return .failure(CableTestOutputError(message: refusal)) }
        var pairs: [CablePairResult] = []
        let pattern = "Pair\\s+([A-D])\\s+(\\d+|N/A)(?:\\s*\\+/-\\s*\\d+)?\\s*(?:meters|meter|m)?\\s+(?:Pair\\s+[A-D]|N/A)\\s+(.+?)\\s*$"
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let g = matches(pattern, in: line), let pair = pairNumber(g[1]),
                  let status = CablePairStatus.parse(g[3]) else { continue }
            pairs.append(CablePairResult(pair: pair, status: status, meters: Int(g[2])))
        }
        return finish(pairs)
    }

    /// HPE Aruba : AOS-CX (une ligne par paire « 1-2 OK 31 ») ou AOS-S (une ligne par port :
    /// état et distance du défaut, sans la paire).
    public static func aruba(_ text: String, port: String) -> Result<[CablePairResult], CableTestOutputError> {
        if let refusal = refusal(in: text) { return .failure(CableTestOutputError(message: refusal)) }
        var pairs: [CablePairResult] = []
        let cx = "(?:^|\\s)(1-2|3-6|4-5|7-8)\\s+([A-Za-z][A-Za-z ]*?)\\s+(\\d+|N/A|-)\\s*(?:m)?\\s*$"
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let g = matches(cx, in: line), let pair = pairNumber(g[1]), let status = CablePairStatus.parse(g[2]) else { continue }
            pairs.append(CablePairResult(pair: pair, status: status, meters: Int(g[3])))
        }
        if !pairs.isEmpty { return finish(pairs) }
        // AOS-S : « 12    MDIX  Open     27m … » ; la paire n'est pas précisée (0).
        let escaped = NSRegularExpression.escapedPattern(for: port)
        let aos = "^\\s*\(escaped)\\s+(?:MDIX|MDI|Auto|-)?\\s*(Good|Open|Short|Impedance|Failed|Normal)\\s+(\\d+)\\s*m"
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let g = matches(aos, in: line), let status = CablePairStatus.parse(g[1]) else { continue }
            let meters = Int(g[2])
            if status == .ok { return .success((1...4).map { CablePairResult(pair: $0, status: .ok) }) }
            return .success([CablePairResult(pair: 0, status: status, meters: meters)])
        }
        return finish([])
    }

    /// FortiSwitch : « diagnose switch physical-ports cable-diag port3 ».
    public static func fortiSwitch(_ text: String) -> Result<[CablePairResult], CableTestOutputError> {
        if let refusal = refusal(in: text) { return .failure(CableTestOutputError(message: refusal)) }
        var pairs: [CablePairResult] = []
        let pattern = "pair\\s+([A-D1-4])\\s*:?\\s*([A-Za-z][A-Za-z \\-]*?)\\s*,\\s*length\\s+(\\d+)"
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let g = matches(pattern, in: line), let pair = pairNumber(g[1]), let status = CablePairStatus.parse(g[2]) else { continue }
            pairs.append(CablePairResult(pair: pair, status: status, meters: Int(g[3])))
        }
        return finish(pairs)
    }

    /// FortiGate : réponse JSON de cable-status (forme tolérante : « results » objet ou tableau,
    /// paires sous « pairs », clés « status », « length » ou « distance »).
    public static func fortiGate(_ data: Data) -> Result<[CablePairResult], CableTestOutputError> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(CableTestOutputError(message: "réponse illisible de la FortiGate."))
        }
        var list: [[String: Any]] = []
        let results = root["results"]
        if let dict = results as? [String: Any] {
            list = (dict["pairs"] as? [[String: Any]]) ?? (dict["cable"] as? [[String: Any]]) ?? []
        } else if let array = results as? [[String: Any]] {
            list = array.first.flatMap { $0["pairs"] as? [[String: Any]] } ?? array
        }
        var pairs: [CablePairResult] = []
        for (offset, item) in list.enumerated() {
            let pairToken = (item["pair"] as? String) ?? (item["pair"] as? Int).map(String.init) ?? String(offset + 1)
            guard let pair = pairNumber(pairToken),
                  let statusText = (item["status"] ?? item["state"] ?? item["result"]) as? String,
                  let status = CablePairStatus.parse(statusText) else { continue }
            let length = (item["length"] ?? item["distance"] ?? item["fault_distance"]) as? Int
            pairs.append(CablePairResult(pair: pair, status: status, meters: length))
        }
        return finish(pairs)
    }

    /// Analyse selon la marque (Cisco : sortie de la dernière étape).
    public static func parse(_ text: String, vendor: CableTestVendor, port: String) -> Result<[CablePairResult], CableTestOutputError> {
        switch vendor {
        case .cisco: return cisco(text)
        case .aruba: return aruba(text, port: port)
        case .fortiSwitch: return fortiSwitch(text)
        }
    }

    private static func finish(_ pairs: [CablePairResult]) -> Result<[CablePairResult], CableTestOutputError> {
        var seen = Set<Int>()
        let unique = pairs.filter { seen.insert($0.pair).inserted }
        guard !unique.isEmpty else {
            return .failure(CableTestOutputError(message: "aucune paire reconnue dans la réponse du switch."))
        }
        return .success(unique.sorted { $0.pair < $1.pair })
    }
}
