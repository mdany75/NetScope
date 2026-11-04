import Foundation
@testable import NetScopeCore

// Conversions numériques sans plantage (suite du plantage de la 0.8.0 : Int(x) avec x infini).
// Chaque fonction corrigée du moteur reçoit NaN, ±infini, 0 et des valeurs hors limites : elle
// doit répondre sans planter, et les valeurs normales gardent leur affichage. Aucun trafic réseau.

func registerSafeNumberTests(_ suite: TestSuite) {
    let nbsp = "\u{00A0}"
    let extremes: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .greatestFiniteMagnitude]

    suite.add("Nombres sûrs : clampedInt et finiteOrNil") {
        try expectEqual(Double.nan.clampedInt, 0, "NaN donne 0")
        try expectEqual(Double.infinity.clampedInt, Int.max, "+∞ ramené à Int.max")
        try expectEqual((-Double.infinity).clampedInt, Int.min, "−∞ ramené à Int.min")
        try expectEqual(Double(0).clampedInt, 0, "0")
        try expectEqual(2.5.clampedInt, 3, "arrondi au plus proche")
        try expectEqual(1e30.clampedInt, Int.max, "hors limites")
        try expect(Double.nan.finiteOrNil == nil && Double.infinity.finiteOrNil == nil, "non fini → nil")
        try expectEqual(4.2.finiteOrNil, 4.2, "fini gardé")
    }

    suite.add("Nombres sûrs : formats d'outils, de sondes et de ressources") {
        for value in extremes {
            _ = ToolFormat.seconds(value)
            _ = ToolFormat.milliseconds(value)
            _ = MonFormat.number(value)
            _ = MonFormat.percent(value)
            _ = ResourceFormat.percent(value)
        }
        try expectEqual(ToolFormat.milliseconds(.infinity), "—", "latence infinie")
        try expectEqual(ToolFormat.seconds(.nan), "—", "durée NaN")
        try expectEqual(ToolFormat.milliseconds(12.4), "12\(nbsp)ms", "latence normale inchangée")
        try expectEqual(ToolFormat.seconds(0.45), "450\(nbsp)ms", "durée normale inchangée")
        try expectEqual(MonFormat.percent(5), "5\(nbsp)%", "perte normale inchangée")
        try expectEqual(MonFormat.percent(0), "0\(nbsp)%", "perte nulle")
        try expectEqual(ResourceFormat.percent(42), "42\(nbsp)%", "pourcentage normal inchangé")
        try expectEqual(ResourceFormat.percent(.nan), "—", "pourcentage NaN")
        _ = ToolFormat.integer(UInt64.max)
        _ = ResourceFormat.memory(UInt64.max)
        _ = ResourceFormat.memory(0)
    }

    suite.add("Nombres sûrs : capture (horodatages, somme de contrôle, texte de tcpdump)") {
        for value in extremes + [1.8e19] {
            let bytes = PcapFile.record(PacketRecord(timestamp: value, data: [1, 2, 3]))
            try expectEqual(bytes.count, 16 + 3, "enregistrement écrit pour \(value)")
        }
        let normal = PcapFile.record(PacketRecord(timestamp: 1.5, data: []))
        try expectEqual(Array(normal[0..<8]), [1, 0, 0, 0, 0x20, 0xA1, 0x07, 0], "1,5 s = 1 s + 500 000 µs")
        // 1 Mio d'octets 0xFF : la somme 32 bits débordait au-delà d'environ 131 Ko.
        try expectEqual(InternetChecksum.checksum([UInt8](repeating: 0xFF, count: 1 << 20)[...]), 0, "longue trame : pas de débordement")
        try expectEqual(InternetChecksum.checksum([0x45, 0x00, 0x00, 0x1C][...]), ~UInt16(0x451C), "petite somme inchangée")
        let text = "10:21:33.123456 IP 1.2.3.4 > 5.6.7.8\n\t0x0000:  ４５００ 001c"
        _ = TcpdumpHexParser.frames(from: text)
    }

    suite.add("Nombres sûrs : ports hors limites, durées et réglages relus") {
        try expect(SvcCatalog.endpoint(from: "https://h.example:99999/x") == nil, "port 99 999 refusé")
        try expect(SvcCatalog.endpoint(from: "https://h.example:0/x") == nil, "port 0 refusé")
        try expect(SvcCatalog.endpoint(from: "https://h.example:8443/x") != nil, "port valide accepté")
        try expect(SvcCatalog.endpoint(from: "status.example.com") != nil, "sans port : accepté")
        try expectEqual(Duration.seconds(Int64.max).scanNanoseconds, UInt64.max, "durée démesurée bornée")
        try expectEqual(Duration.zero.scanNanoseconds, 0, "durée nulle")
        try expectEqual(Duration.milliseconds(500).scanNanoseconds, 500_000_000, "durée normale inchangée")
        let json = Data(#"{"groupWindow": 1e300}"#.utf8)
        let settings = try JSONDecoder().decode(NotificationSettings.self, from: json)
        try expectEqual(settings.groupWindow, 86_400, "fenêtre de regroupement bornée à un jour")
    }

    suite.add("Nombres sûrs : JSON d'iperf3 et d'Ookla non finis") {
        try expect(IperfParser.double("inf") == nil, "« inf » refusé")
        try expect(IperfParser.double("nan") == nil, "« nan » refusé")
        try expect(IperfParser.double(NSNumber(value: Double.infinity)) == nil, "nombre infini refusé")
        try expectEqual(IperfParser.double("12.5"), 12.5, "valeur normale")
        func ookla(_ loss: Any) throws -> SpeedTestSummary {
            try OoklaParser.result(["ping": ["latency": 8.0], "download": ["bandwidth": 12_500_000.0],
                                    "upload": ["bandwidth": 2_500_000.0], "packetLoss": loss])
        }
        try expectEqual(try ookla("nan").probesLost, 0, "perte NaN ignorée")
        try expectEqual(try ookla(1e300).probesLost, 1000, "perte démesurée bornée à 100 %")
        try expectEqual(try ookla(0.4).probesLost, 4, "perte normale inchangée")
    }
}
