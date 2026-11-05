import Foundation
import NetScopeCore

// Réponses de FortiOS rendues invalides par des restes de mémoire (constat réel : FortiOS 7.4.13,
// monitor/wifi/client, champ « triangulation_regions ») : la lecture les répare au lieu de laisser
// une liste vide, et dit quand une partie reste illisible ou vide. Aucun réseau.

/// Transport de test aux corps en octets bruts (les fixtures texte ne peuvent pas porter d'octets invalides).
private final class FortiByteTransport: FortiTransport, @unchecked Sendable {
    private let responses: [String: (Int, Data)]
    init(_ responses: [String: (Int, Data)]) { self.responses = responses }
    func get(_ path: String, query: [URLQueryItem]) async throws -> FortiHTTPResponse {
        guard let (status, body) = responses[path] else {
            return FortiHTTPResponse(status: 404, body: Data(#"{"http_method":"GET","status":"error","http_status":404}"#.utf8))
        }
        return FortiHTTPResponse(status: status, body: body)
    }
}

private enum FortiRepairFixtures {
    /// Deux clients de la borne FP231F ; le second porte des octets hors UTF-8 et un caractère de
    /// contrôle dans « triangulation_regions », comme la réponse réelle.
    static var clientsWithGarbage: Data {
        var d = Data(#"""
        {"http_method":"GET","results":[{"ip":"10.93.226.154","wtp_name":"FP231FTF2209A2H4","wtp_id":"FP231FTF2209A2H4","wtp_radio":2,
        "vap_name":"GC Data","ssid":"GC Data","mac":"6e:91:49:d7:9e:e6","hostname":"iPhone","snr":26,"channel":100,"signal":-69,
        "radio_type":"802.11ax-5G","health":{"snr":{"value":26,"severity":"good"}}},
        {"ip":"10.93.226.111","wtp_name":"FP231FTF2209A2H4","wtp_id":"FP231FTF2209A2H4","wtp_radio":2,"vap_name":"Groupe Couture",
        "ssid":"Groupe Couture","mac":"04:c1:03:ba:91:ae","hostname":"Clover-Flex-4-C406","channel":100,"signal":-70,
        "triangulation_regions":[{"wtp_id":"
        """#.utf8)
        d.append(contentsOf: [0xFF, 0xFE, 0x83, 0x01, 0x45])
        d.append(Data(#"""
        AES/TKIP","rssi":0,"last_seen":117564565946368}],"health":{"snr":{"value":25,"severity":"good"}}}],
        "vdom":"root","path":"wifi","name":"client","status":"success","version":"v7.4.13","build":2933}
        """#.utf8))
        return d
    }

    /// Octets invalides ET guillemet parasite : seule la suppression de « triangulation_regions » sauve la réponse.
    static var clientsWithBrokenQuote: Data {
        var d = Data(#"{"results":[{"mac":"aa:92:eb:51:00:1f","ssid":"Groupe Couture","triangulation_regions":[{"wtp_id":"x"#.utf8)
        d.append(contentsOf: [0x22, 0xC3, 0x28, 0x22, 0x22])
        d.append(Data(#"","rssi":0}],"signal":-60}],"status":"success"}"#.utf8))
        return d
    }

    static let managedAP = #"""
    {"results":[{"name":"FP231FTF2209A2H4","serial":"FP231FTF2209A2H4","wtp_id":"FP231FTF2209A2H4","status":"connected","clients":16,
     "radio":[{"radio_id":1,"client_count":2,"oper_chan":1},{"radio_id":2,"client_count":14,"oper_chan":100}]}],"status":"success"}
    """#
}

func registerFortiJSONRepairTests(_ suite: TestSuite) {
    let now = Date(timeIntervalSince1970: 1_793_901_000)

    suite.add("FortiOS : JSON aux octets invalides réparé (triangulation_regions de FortiOS 7.4.13)") {
        let data = FortiRepairFixtures.clientsWithGarbage
        try expect((try? JSONSerialization.jsonObject(with: data)) == nil, "réponse brute bien invalide pour JSONSerialization")
        try expect(FortiJSON.needsRepair(data), "réparation nécessaire et suffisante")
        let clients = try FortiWifiParsers.clients(data, now: now).unwrap("clients lus malgré les octets invalides")
        try expectEqual(clients.count, 2, "les deux clients")
        try expectEqual(clients[1].hostname, "Clover-Flex-4-C406", "client abîmé lu quand même")
        try expectEqual(clients[1].rssi, -70, "signal du client abîmé")
    }

    suite.add("FortiOS : guillemet parasite, triangulation_regions retiré ; JSON valide inchangé") {
        let broken = FortiRepairFixtures.clientsWithBrokenQuote
        let clients = try FortiWifiParsers.clients(broken, now: now).unwrap("lu après retrait de triangulation_regions")
        try expectEqual(clients.count, 1, "un client")
        try expectEqual(clients[0].rssi, -60, "champ après le tableau retiré conservé")
        let valid = Data(FortiWifiFixtures.client74.utf8)
        try expect(!FortiJSON.needsRepair(valid), "réponse valide jamais marquée réparée")
        try expect(FortiJSON.parse(Data("pas du json".utf8)) == nil, "texte quelconque toujours refusé")
        try expect(FortiJSON.parse(Data([0xFF, 0xFE])) == nil, "octets seuls toujours refusés")
    }

    suite.add("FortiAP : clients réparés à la lecture, réponse réparée signalée dans le diagnostic") {
        let transport = FortiByteTransport([
            FortiWifiPaths.managedAP: (200, Data(FortiRepairFixtures.managedAP.utf8)),
            FortiWifiPaths.client: (200, FortiRepairFixtures.clientsWithGarbage),
        ])
        let report = try await FortiGateReader(transport: transport).readWifi(now: now)
        try expectEqual(report.clients.count, 2, "clients lus")
        try expect(!report.notes.contains { $0.contains("annoncent") || $0.contains("illisible") }, "aucune alerte quand tout est lu")
        let call = try report.calls.first { $0.path == FortiWifiPaths.client }.unwrap("appel des clients")
        try expect(call.message.contains("réparée"), "diagnostic : réponse réparée")
    }

    suite.add("FortiAP : clients illisibles ou absents de la liste, jamais un 0 silencieux") {
        let garbage = FortiByteTransport([
            FortiWifiPaths.managedAP: (200, Data(FortiRepairFixtures.managedAP.utf8)),
            FortiWifiPaths.client: (200, Data([0x7B, 0x22, 0xFF, 0x00, 0x5B])),
        ])
        let unreadable = try await FortiGateReader(transport: garbage).readWifi(now: now)
        try expect(unreadable.clients.isEmpty, "rien d'inventé")
        try expect(unreadable.notes.contains { $0.hasPrefix("Clients Wi-Fi") && $0.contains("illisible") }, "réponse illisible dite : \(unreadable.notes)")
        try expect(unreadable.notes.contains { $0.contains("annoncent 16 clients") }, "écart avec les bornes dit : \(unreadable.notes)")

        let empty = FortiByteTransport([
            FortiWifiPaths.managedAP: (200, Data(FortiRepairFixtures.managedAP.utf8)),
            FortiWifiPaths.client: (200, Data(#"{"results":[],"status":"success"}"#.utf8)),
        ])
        let none = try await FortiGateReader(transport: empty).readWifi(now: now)
        try expect(none.notes.contains { $0.contains("annoncent 16 clients") }, "liste vide alors que les bornes ont des clients")
        try expect(!none.notes.contains { $0.contains("illisible") }, "liste vide n'est pas illisible")

        let quiet = FortiByteTransport([
            FortiWifiPaths.managedAP: (200, Data(#"{"results":[{"name":"AP1","status":"connected","radio":[{"radio_id":1,"client_count":0}]}]}"#.utf8)),
            FortiWifiPaths.client: (200, Data(#"{"results":[]}"#.utf8)),
        ])
        let calm = try await FortiGateReader(transport: quiet).readWifi(now: now)
        try expect(!calm.notes.contains { $0.contains("annoncent") }, "aucun client annoncé : rien à signaler")
    }
}

private extension Optional {
    func unwrap(_ what: String, file: String = #fileID, line: Int = #line) throws -> Wrapped {
        guard let value = self else { throw TestFailure(message: "\(what) : nil", file: file, line: line) }
        return value
    }
}
