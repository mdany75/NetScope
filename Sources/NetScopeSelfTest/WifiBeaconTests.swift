import Foundation
import NetScopeCore

// Note 71 : éléments des balises Wi-Fi. Octets fixes au format des balises des bornes citées
// (structure élément par élément d'après IEEE 802.11-2020 et les dissecteurs de Wireshark) ;
// aucun appel à CoreWLAN ni au réseau.

/// Octets d'une chaîne hexadécimale (espaces et retours à la ligne ignorés).
private func hex(_ text: String) -> [UInt8] {
    let digits = text.filter(\.isHexDigit)
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

private let wmm = "dd 18 0050f202 01 01 80 00 03a40000 27a40000 42435e00 62322f00"
private let zeros16 = "00000000 00000000 00000000 00000000"

enum WifiBeaconFixtures {
    /// Cisco C9120AXI (contrôleur 8.10), 5 GHz canal 36 à 80 MHz, WPA2-Entreprise + FT,
    /// 11k/v/r, élément Aironet 133 avec le nom de la borne.
    static let ciscoC9120 = hex("""
        00 09 434f52502d574c414e
        01 08 8c129824b048606c
        03 01 24
        05 04 00010000
        07 06 434120240417
        0b 05 0c002d0000
        2d 1a ef09 17 ffff0000000000000000 0000 00 000000 0000 00000000 00
        3d 16 24 05 0000 0000 \(zeros16)
        30 18 0100 000fac04 0100 000fac04 0200 000fac01 000fac03 2800
        36 03 2b1a01
        46 05 73d000000c
        7f 08 0400080000000040
        bf 0c b279830f faff 0000 faff 0000
        c0 05 01 2a 00 fcff
        ff 16 23 0d01081a4000 04700c897f038004000000 faff faff
        ff 07 24 f40100 2a fcff
        \(wmm)
        85 1e 00008f000f00ff035900 41502d43393132302d32462d53554400 0c 000025
        dd 05 0040960305
        """)

    /// FortiAP 431F, 2,4 GHz canal 6, transition WPA2/WPA3 avec FT, PMF facultative, cellule chargée,
    /// élément Fortinet (nom, modèle, numéro de série).
    static let fortiAP431F = hex("""
        00 0a 41434d452d5374616666
        01 08 82848b960c121824
        03 01 06
        05 04 00020000
        07 06 434120010b1e
        2a 01 00
        32 04 3048606c
        0b 05 2900c40000
        2d 1a ad01 17 ffffffff000000000000 0000 00 000000 0000 00000000 00
        3d 16 06 00 0000 0000 \(zeros16)
        30 20 0100 000fac04 0100 000fac04 0400 000fac02 000fac08 000fac04 000fac09 8000
        36 03 e34c00
        46 05 7200010000
        7f 0b 0500080000000040000001
        ff 16 23 0d01081a4000 04700c897f038004000000 00ff 00ff
        ff 07 24 f40100 15 fcff
        \(wmm)
        dd 2f 00090f 0a00 01 0d 4641502d52482d457461676532 02 07 46415034333146 03 10 46503433314654463230303132333435
        """)

    /// Aruba AP-515, 5 GHz canal 149 à 80 MHz, WPA2-Entreprise sans PMF, 11k seulement,
    /// élément Aruba « AP Name » (et un autre sous-type sans nom).
    static let arubaAP515 = hex("""
        00 0d 456e747265706f742d4e6f7264
        01 08 8c129824b048606c
        03 01 95
        05 04 00010000
        0b 05 1700a60000
        2d 1a ef09 17 ffff0000000000000000 0000 00 000000 0000 00000000 00
        3d 16 95 05 0000 0000 \(zeros16)
        30 14 0100 000fac04 0100 000fac04 0100 000fac01 0000
        46 05 7300000000
        7f 08 0400000000000040
        bf 0c b279830f faff 0000 faff 0000
        c0 05 01 9b 00 fcff
        ff 16 23 0d01081a4000 04700c897f038004000000 faff faff
        ff 07 24 f40100 07 fcff
        \(wmm)
        dd 07 000b86 01 04 08 13
        dd 13 000b86 03 00 41502d454e545245504f542d4e31
        """)

    /// Ubiquiti U6 Enterprise, 6 GHz canal 37 à 80 MHz (sans HT ni VHT), WPA3-SAE, PMF obligatoire.
    static let ubiquiti6GHz = hex("""
        00 0d 55424e542d4c6f67697374696b
        01 08 8c129824b048606c
        05 04 00010000
        0b 05 0500260000
        30 14 0100 000fac04 0100 000fac04 0100 000fac08 cc00
        46 05 7300000000
        7f 0a 04000800000000400000
        ff 16 23 0d01081a4000 04700c897f038004000000 faff faff
        ff 0c 24 f40102 05 fcff 25 02 27 00 0b
        ff 03 3b b830
        """)

    /// Borne Wi-Fi 7 en 6 GHz à 320 MHz, SAE et SAE à clé étendue, GCMP-256.
    static let wifi7 = hex("""
        00 09 566f6973696e2d3645
        01 08 8c129824b048606c
        0b 05 0300140000
        30 18 0100 000fac09 0100 000fac09 0200 000fac08 000fac18 c000
        ff 16 23 0d01081a4000 04700c897f038004000000 faff faff
        ff 0c 24 f40102 11 fcff 45 03 4f 00 0b
        ff 0e 6c 00000000000000000000 222222
        ff 09 6a 01 44444444 04 5f 00
        """)

    /// Routeur domestique TP-Link 2,4 GHz : WPA/WPA2-PSK mixte (élément WPA1), WPS.
    static let tpLink = hex("""
        00 0b 436166652d566f6973696e
        01 08 82848b960c121824
        03 01 01
        05 04 00010000
        07 06 434120010b1e
        2a 01 04
        32 04 3048606c
        30 18 0100 000fac02 0200 000fac04 000fac02 0100 000fac02 0000
        2d 1a ec11 17 ff000000000000000000 0000 00 000000 0000 00000000 00
        3d 16 01 00 0000 0000 \(zeros16)
        dd 1a 0050f201 0100 0050f202 0200 0050f204 0050f202 0100 0050f202
        dd 39 0050f204 104a000110 1044000102 10210007 54502d4c696e6b 10230009 417263686572204336 1011000f 576972656c65737320526f75746572
        \(wmm)
        """)

    /// Réseau ouvert jumelé à un BSSID OWE (élément de transition OWE de la Wi-Fi Alliance).
    static let oweOpen = hex("""
        00 0c 496e766974652d4c69627265
        01 08 82848b960c121824
        03 01 06
        dd 0b 506f9a1c 7c4ca51e22a2 00
        """)
}

func registerWifiBeaconTests(_ suite: TestSuite) {
    suite.add("Wi-Fi balises : Cisco C9120 (5 GHz, 11k/v/r, nom Aironet)") {
        let info = WifiBeaconParser.parse(WifiBeaconFixtures.ciscoC9120)
        try expect(!info.isTruncated, "balise complète")
        try expectEqual(info.ssid, "CORP-WLAN", "SSID")
        try expectEqual(info.channel, 36, "canal")
        try expectEqual(info.countryCode, "CA", "pays")
        try expectEqual(info.dtimPeriod, 1, "DTIM")
        try expectEqual(info.bssLoad?.stationCount, 12, "clients")
        try expectEqual(info.bssLoad?.utilizationPercent, 18, "utilisation 45/255")
        try expectEqual(info.generation(band: .ghz5), .wifi6, "Wi-Fi 6")
        try expectEqual(info.channelWidthMHz, 80, "largeur")
        try expectEqual(info.spatialStreams, 2, "flux")
        try expect(info.supports11k && info.supports11v && info.supports11r, "11k/v/r")
        try expectEqual(info.roamingSummary, "k v r", "résumé")
        try expectEqual(info.mobilityDomain?.mdidText, "1A2B", "MDID")
        try expect(info.mobilityDomain?.overDS == true, "FT par le DS")
        try expectEqual(info.security, .wpa2Enterprise, "sécurité")
        try expectEqual(info.pmf, .absent, "PMF")
        try expectEqual(info.rsn?.akmLabels ?? [], ["802.1X", "FT-802.1X"], "AKM")
        try expectEqual(info.rsn?.pairwiseLabels ?? [], ["CCMP-128"], "chiffre")
        try expectEqual(info.apName, "AP-C9120-2F-SUD", "nom Cisco")
        try expectEqual(info.apNameSource, .cisco, "source")
        try expectEqual(info.ciscoClientCount, 12, "clients Cisco")
    }

    suite.add("Wi-Fi balises : FortiAP 431F (transition WPA3, cellule saturée, nom Fortinet)") {
        let info = WifiBeaconParser.parse(WifiBeaconFixtures.fortiAP431F)
        try expect(!info.isTruncated, "balise complète")
        try expectEqual(info.ssid, "ACME-Staff", "SSID")
        try expectEqual(info.channel, 6, "canal")
        try expectEqual(info.dtimPeriod, 2, "DTIM")
        try expectEqual(info.generation(band: .ghz24), .wifi6, "Wi-Fi 6 en 2,4 GHz")
        try expectEqual(info.channelWidthMHz, 20, "20 MHz")
        try expectEqual(info.spatialStreams, 4, "4 flux")
        try expectEqual(info.bssLoad?.stationCount, 41, "clients")
        try expectEqual(info.bssLoad?.utilizationPercent, 77, "utilisation")
        try expect(WifiBeaconAdvisor.isSaturated(info.bssLoad!), "saturée")
        try expectEqual(info.security, .wpa3Transition, "transition WPA2/WPA3")
        try expectEqual(info.pmf, .optional, "PMF facultative")
        try expect(info.rsn!.hasFT, "AKM FT")
        try expect(info.supports11k && info.supports11v && info.supports11r, "11k/v/r")
        try expectEqual(info.apName, "FAP-RH-Etage2", "nom")
        try expectEqual(info.apNameSource, .fortinet, "source")
        try expectEqual(info.apModel, "FAP431F", "modèle")
        try expectEqual(info.apSerial, "FP431FTF20012345", "série")
    }

    suite.add("Wi-Fi balises : Aruba AP-515 (11k seul, WPA2-Entreprise sans PMF)") {
        let info = WifiBeaconParser.parse(WifiBeaconFixtures.arubaAP515)
        try expect(!info.isTruncated, "balise complète")
        try expectEqual(info.channel, 149, "canal")
        try expectEqual(info.channelWidthMHz, 80, "80 MHz")
        try expect(info.supports11k, "11k")
        try expect(!info.supports11v, "pas de 11v")
        try expect(!info.supports11r, "pas de 11r")
        try expectEqual(info.missingRoaming, ["802.11v", "802.11r"], "fonctions absentes")
        try expectEqual(info.roamingSummary, "k – –", "résumé")
        try expectEqual(info.security, .wpa2Enterprise, "sécurité")
        try expectEqual(info.pmf, .absent, "sans PMF")
        try expectEqual(info.apName, "AP-ENTREPOT-N1", "nom Aruba")
        try expectEqual(info.apNameSource, .aruba, "source")
        try expectEqual(info.bssLoad?.utilizationPercent, 65, "utilisation")
    }

    suite.add("Wi-Fi balises : 6 GHz (Wi-Fi 6E) et Wi-Fi 7 à 320 MHz") {
        let six = WifiBeaconParser.parse(WifiBeaconFixtures.ubiquiti6GHz)
        try expect(!six.isTruncated, "6E complète")
        try expect(!six.hasHT && !six.hasVHT, "ni HT ni VHT en 6 GHz")
        try expectEqual(six.generation(), .wifi6E, "6E sans indice de bande")
        try expectEqual(six.channel, 37, "canal primaire 6 GHz")
        try expectEqual(six.channelWidthMHz, 80, "80 MHz")
        try expectEqual(six.security, .wpa3Personal, "WPA3-SAE")
        try expectEqual(six.pmf, .required, "PMF obligatoire")
        try expectEqual(six.roamingSummary, "k v –", "11k et 11v")
        let seven = WifiBeaconParser.parse(WifiBeaconFixtures.wifi7)
        try expect(!seven.isTruncated, "Wi-Fi 7 complète")
        try expectEqual(seven.generation(band: .ghz6), .wifi7, "Wi-Fi 7")
        try expectEqual(seven.channelWidthMHz, 320, "320 MHz")
        try expectEqual(seven.channel, 69, "canal")
        try expectEqual(seven.security, .wpa3Personal, "SAE")
        try expectEqual(seven.rsn?.akmLabels ?? [], ["SAE", "SAE (clé étendue)"], "AKM")
        try expectEqual(seven.rsn?.pairwiseLabels ?? [], ["GCMP-256"], "GCMP-256")
        try expectEqual(WifiGeneration.wifi6E.standard, "802.11ax", "norme 6E")
        try expect(WifiGeneration.wifi6E < .wifi7 && WifiGeneration.wifi6 < .wifi6E, "ordre des générations")
    }

    suite.add("Wi-Fi balises : routeur domestique (WPA1 + WPA2, WPS) et transition OWE") {
        let info = WifiBeaconParser.parse(WifiBeaconFixtures.tpLink)
        try expect(!info.isTruncated, "balise complète")
        try expectEqual(info.generation(band: .ghz24), .wifi4, "Wi-Fi 4")
        try expectEqual(info.spatialStreams, 1, "1 flux")
        try expectEqual(info.security, .wpa2Personal, "RSN l'emporte sur WPA1")
        try expect(info.wpa != nil, "élément WPA1 lu")
        try expectEqual(info.rsn?.groupLabel, "TKIP", "groupe TKIP")
        try expectEqual(info.wpsDeviceName, "Wireless Router", "nom WPS")
        try expectEqual(info.wpsManufacturer, "TP-Link", "fabricant WPS")
        try expectEqual(info.wpsModel, "Archer C6", "modèle WPS")
        try expect(info.apName == nil, "pas de nom de borne propriétaire")
        try expectEqual(info.roamingSummary, "– – –", "aucune fonction d'itinérance")
        try expect(info.bssLoad == nil, "pas de BSS Load")
        let owe = WifiBeaconParser.parse(WifiBeaconFixtures.oweOpen)
        try expect(owe.oweTransition, "transition OWE")
        try expect(owe.security == nil, "réseau ouvert : sécurité laissée à CoreWLAN")
    }

    suite.add("Wi-Fi balises : champs fixes devant les éléments, SSID caché") {
        let fixed = hex("8a3c9d0e01000000 6400 3114") + WifiBeaconFixtures.fortiAP431F
        let info = WifiBeaconParser.parse(fixed)
        try expect(info.hadFixedFields, "champs fixes reconnus")
        try expect(!info.isTruncated, "rien de tronqué")
        try expectEqual(info.apName, "FAP-RH-Etage2", "même décodage")
        try expectEqual(info, { var copy = WifiBeaconParser.parse(WifiBeaconFixtures.fortiAP431F); copy.hadFixedFields = true; return copy }(), "identique")
        try expect(WifiBeaconParser.parse(hex("00 00 03 01 0b")).ssid == nil, "SSID vide")
        try expect(WifiBeaconParser.parse(hex("00 04 00000000 03 01 0b")).ssid == nil, "SSID à zéro")
        try expectEqual(WifiBeaconParser.parse(Data(WifiBeaconFixtures.ciscoC9120)).apName, "AP-C9120-2F-SUD", "lecture depuis Data")
    }

    suite.add("Wi-Fi balises : éléments tronqués ou malformés sans plantage") {
        let full = WifiBeaconFixtures.ciscoC9120
        let boundaries = Set(elementBoundaries(full))
        for length in 0..<full.count {
            let info = WifiBeaconParser.parse(Array(full.prefix(length)))
            if !boundaries.contains(length) { try expect(info.isTruncated, "coupure à \(length) signalée") }
            _ = (info.generation(), info.security, info.roamingSummary, info.pmf)
        }
        let malformed: [(String, (WifiBeaconInfo) -> Bool)] = [
            ("30 08 0100 000fac04 ffff", { $0.rsn == nil && $0.isTruncated }),
            ("30 02 0100", { $0.rsn?.version == 1 && $0.security == .unknown && !$0.isTruncated }),
            ("0b 02 0500", { $0.bssLoad == nil && $0.isTruncated }),
            ("ff 07 24 f40102 05 fcff", { $0.he6GHz && $0.isTruncated && $0.channelWidthMHz == nil }),
            ("ff 04 6a 01 4444", { $0.hasEHT && $0.isTruncated }),
            ("ff 06 6a 01 44444444", { $0.hasEHT && $0.isTruncated }),
            ("dd 01 00", { $0.isTruncated }),
            ("dd 0a 00090f 0a00 01 20 414243", { $0.apName == nil && $0.isTruncated }),
            ("85 05 0000000000", { $0.apName == nil && $0.isTruncated }),
            ("7f 01 04", { !$0.bssTransition }),
            ("ff 00 03 01 06", { $0.channel == 6 }),
            ("30 40 0100", { $0.rsn == nil && $0.isTruncated }),
            ("46 00", { $0.radioMeasurement && !$0.neighborReport && $0.isTruncated }),
            ("36 01 2b", { $0.mobilityDomain == nil && $0.isTruncated }),
            ("dd 0c 0050f204 1011 ffff 41424344", { $0.wpsDeviceName == nil && $0.isTruncated }),
            ("2d 02 ef09", { $0.hasHT && $0.spatialStreams == nil && $0.isTruncated }),
            ("c0 05 07 2a 00 fcff", { $0.channelWidthMHz == nil }),
        ]
        for (text, check) in malformed {
            try expect(check(WifiBeaconParser.parse(hex(text))), "élément malformé \(text)")
        }
        // Nom avec caractères de contrôle et octets invalides : nettoyé.
        let dirty = WifiBeaconParser.parse(hex("dd 10 00090f 0a00 01 07 0a4150ff2d3109 0200"))
        try expectEqual(dirty.apName, "AP-1", "nom nettoyé")
        // Octets aléatoires et balises abîmées (générateur déterministe).
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 33
        }
        for _ in 0..<3000 {
            let bytes = (0..<Int(next() % 300)).map { _ in UInt8(truncatingIfNeeded: next()) }
            let info = WifiBeaconParser.parse(bytes)
            _ = (info.generation(band: .ghz6), info.security, info.roamingSummary)
        }
        let fixtures = [WifiBeaconFixtures.ciscoC9120, WifiBeaconFixtures.fortiAP431F, WifiBeaconFixtures.arubaAP515,
                        WifiBeaconFixtures.ubiquiti6GHz, WifiBeaconFixtures.wifi7, WifiBeaconFixtures.tpLink]
        for _ in 0..<3000 {
            var bytes = fixtures[Int(next() % UInt64(fixtures.count))]
            for _ in 0..<(1 + Int(next() % 4)) { bytes[Int(next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: next()) }
            let info = WifiBeaconParser.parse(bytes)
            _ = (info.generation(), info.security, info.missingRoaming, info.bssLoad?.utilizationPercent)
        }
    }

    suite.add("Wi-Fi balises : encodeur de démonstration, aller-retour") {
        let bytes = WifiBeaconBuilder.ssid("Bureau-Corp") + WifiBeaconBuilder.dsParameter(channel: 44)
            + WifiBeaconBuilder.tim(dtimPeriod: 3) + WifiBeaconBuilder.country("CA", firstChannel: 36, count: 8, maxPower: 23)
            + WifiBeaconBuilder.bssLoad(clients: 46, utilizationPercent: 81)
            + WifiBeaconBuilder.htCapabilities(streams: 2) + WifiBeaconBuilder.htOperation(primary: 44, width40: true)
            + WifiBeaconBuilder.vhtCapabilities(streams: 4) + WifiBeaconBuilder.vhtOperation(widthMHz: 160, center: 50)
            + WifiBeaconBuilder.heCapabilities(streams: 4) + WifiBeaconBuilder.heOperation()
            + WifiBeaconBuilder.rsn(akms: [5, 3], pmf: .required) + WifiBeaconBuilder.mobilityDomain(0x4ce3, overDS: false)
            + WifiBeaconBuilder.rmCapabilities(neighborReport: true) + WifiBeaconBuilder.extendedCapabilities(bssTransition: true)
            + WifiBeaconBuilder.wmm() + WifiBeaconBuilder.fortinet(name: "FAP-Accueil-01", model: "FAP431F", serial: "FP431FTF21000001")
        let info = WifiBeaconParser.parse(bytes)
        try expect(!info.isTruncated, "complet")
        try expectEqual(info.channel, 44, "canal")
        try expectEqual(info.dtimPeriod, 3, "DTIM")
        try expectEqual(info.bssLoad?.utilizationPercent, 81, "utilisation")
        try expectEqual(info.channelWidthMHz, 160, "160 MHz")
        try expectEqual(info.spatialStreams, 4, "flux")
        try expectEqual(info.security, .wpa3Enterprise, "802.1X-SHA256 + PMF obligatoire")
        try expectEqual(info.roamingSummary, "k v r", "itinérance")
        try expectEqual(info.apName, "FAP-Accueil-01", "nom")
        let others = WifiBeaconBuilder.ssid("X") + WifiBeaconBuilder.aruba(name: "AP-01") + WifiBeaconBuilder.cisco(name: "AP-C9130", clients: 7)
        let parsed = WifiBeaconParser.parse(others)
        try expectEqual(parsed.apName, "AP-C9130", "le dernier nom lu l'emporte")
        try expectEqual(parsed.ciscoClientCount, 7, "clients Cisco")
        let seven = WifiBeaconParser.parse(WifiBeaconBuilder.ssid("S") + WifiBeaconBuilder.heCapabilities(streams: 2)
            + WifiBeaconBuilder.heOperation(sixGHz: (37, 160, 47)) + WifiBeaconBuilder.ehtCapabilities()
            + WifiBeaconBuilder.ehtOperation(widthMHz: 320, center: 63) + WifiBeaconBuilder.rsn(akms: [24], pairwise: [9], group: 9, pmf: .required)
            + WifiBeaconBuilder.wps(device: "Box", manufacturer: "Fab", model: "M1") + WifiBeaconBuilder.oweTransition())
        try expect(!seven.isTruncated, "complet (7)")
        try expectEqual(seven.generation(), .wifi7, "Wi-Fi 7")
        try expectEqual(seven.channelWidthMHz, 320, "320 MHz")
        try expectEqual(seven.wpsDeviceName, "Box", "WPS")
        try expect(seven.oweTransition, "OWE")
    }

    suite.add("Wi-Fi balises : constats d'itinérance, de saturation et de WPA3") {
        func network(_ ssid: String, _ bssid: String, _ band: WifiBand, _ channel: Int, _ rssi: Int, _ bytes: [UInt8],
                     connected: Bool = false) -> WifiNetwork {
            WifiNetwork(ssid: ssid, bssid: MACAddress(bssid), channel: channel, band: band, widthMHz: 20, rssi: rssi,
                        isConnected: connected, beacon: WifiBeaconParser.parse(bytes))
        }
        let base = WifiBeaconBuilder.htCapabilities(streams: 2) + WifiBeaconBuilder.heCapabilities(streams: 2) + WifiBeaconBuilder.heOperation()
        let full = WifiBeaconBuilder.rmCapabilities(neighborReport: true) + WifiBeaconBuilder.extendedCapabilities(bssTransition: true)
            + WifiBeaconBuilder.mobilityDomain(1, overDS: false)
        let sae = WifiBeaconBuilder.rsn(akms: [8], pmf: .required)
        let dot1x = WifiBeaconBuilder.rsn(akms: [1])
        // Deux bornes sans aucune fonction d'itinérance.
        var list = [
            network("Corp", "70:4C:A5:00:01:10", .ghz5, 36, -50, base + dot1x, connected: true),
            network("Corp", "70:4C:A5:00:02:10", .ghz5, 52, -60, base + dot1x),
        ]
        var recos = WifiBeaconAdvisor.recommendations(networks: list, connected: list[0])
        let roaming = recos.first { $0.id == "itinerance-Corp" }
        try expect(roaming?.severity == .alerte, "itinérance sans 11k/v/r : alerte")
        try expect(roaming?.title.contains("sans 802.11k/v/r") == true, "titre")
        try expect(roaming?.detail.contains("RADIUS") == true, "802.1X sans 11r expliqué")
        try expect(recos.contains { $0.id == "wpa3-Corp" && $0.title.contains("sans PMF") }, "WPA2-Entreprise sans PMF en Wi-Fi 6")
        // Une borne sans 11r, l'autre complète : itinérance incomplète, borne nommée.
        list = [
            network("Corp", "70:4C:A5:00:01:10", .ghz5, 36, -50, base + sae + full + WifiBeaconBuilder.fortinet(name: "FAP-A"), connected: true),
            network("Corp", "70:4C:A5:00:02:10", .ghz5, 52, -60, base + sae + WifiBeaconBuilder.rmCapabilities(neighborReport: true)
                    + WifiBeaconBuilder.extendedCapabilities(bssTransition: true) + WifiBeaconBuilder.fortinet(name: "FAP-B")),
        ]
        recos = WifiBeaconAdvisor.recommendations(networks: list, connected: list[0])
        let partial = recos.first { $0.id == "itinerance-Corp" }
        try expect(partial?.severity == .conseil, "incomplète : conseil")
        try expect(partial?.title.contains("incomplète") == true, "titre incomplète")
        try expect(partial?.detail.contains("802.11r absent sur FAP-B") == true, "borne fautive nommée")
        try expectEqual(partial?.networkID, list[1].id, "focus sur la borne fautive")
        // Même borne sur deux bandes : pas d'itinérance entre bornes.
        list = [
            network("Maison", "9C:53:22:00:00:01", .ghz24, 6, -50, base + sae),
            network("Maison", "9C:53:22:00:00:02", .ghz5, 36, -55, base + sae),
        ]
        try expect(!WifiBeaconAdvisor.recommendations(networks: list, connected: nil).contains { $0.id.hasPrefix("itinerance") },
                   "une seule borne")
        // Saturation : utilisation, clients, seuils, plusieurs SSID sur la même radio.
        let busy = [
            network("Corp", "70:4C:A5:00:03:10", .ghz24, 6, -55, base + sae + full + WifiBeaconBuilder.bssLoad(clients: 30, utilizationPercent: 77)
                    + WifiBeaconBuilder.fortinet(name: "FAP-RH")),
            network("Invite", "70:4C:A5:00:03:11", .ghz24, 6, -56, base + WifiBeaconBuilder.bssLoad(clients: 15, utilizationPercent: 77)),
            network("Calme", "70:4C:A5:00:04:10", .ghz5, 36, -60, base + sae + WifiBeaconBuilder.bssLoad(clients: 40, utilizationPercent: 69)),
            network("Foule", "70:4C:A5:00:05:10", .ghz5, 149, -60, base + sae + WifiBeaconBuilder.bssLoad(clients: 41, utilizationPercent: 20)),
            network("Plein", "70:4C:A5:00:06:10", .ghz5, 100, -60, base + sae + WifiBeaconBuilder.bssLoad(clients: 5, utilizationPercent: 93)),
        ]
        recos = WifiBeaconAdvisor.saturation(busy, connected: nil)
        try expectEqual(recos.count, 3, "trois radios saturées")
        try expectEqual(recos.first?.severity, .critique, "93 % : critique")
        let rh = recos.first { $0.title.contains("FAP-RH") }
        try expect(rh?.detail.contains("45 clients") == true, "clients des deux SSID additionnés")
        try expect(rh?.detail.contains("2 SSID") == true, "SSID de la radio cités")
        try expect(!recos.contains { $0.title.contains("Calme") }, "sous les seuils")
        try expect(recos.contains { $0.detail.contains("41 clients") }, "plus de 40 clients")
        // WPA3 : WPA2-PSK seul sur Wi-Fi 6 ; Wi-Fi 4 seul : rien ; Wi-Fi 4 avec un BSSID SAE voisin : constat.
        let psk = WifiBeaconBuilder.rsn(akms: [2])
        let legacy = WifiBeaconBuilder.htCapabilities(streams: 1) + WifiBeaconBuilder.htOperation(primary: 6, width40: false)
        try expect(WifiBeaconAdvisor.wpa3([network("A", "11:22:33:00:00:01", .ghz5, 36, -50, base + psk)], connected: nil).count == 1,
                   "Wi-Fi 6 en WPA2 seul")
        try expect(WifiBeaconAdvisor.wpa3([network("B", "11:22:33:00:00:02", .ghz24, 1, -50, legacy + psk)], connected: nil).isEmpty,
                   "Wi-Fi 4 seul : pas de constat")
        let mixed = WifiBeaconAdvisor.wpa3([network("C", "11:22:33:00:00:03", .ghz24, 1, -50, legacy + psk),
                                            network("C", "11:22:33:00:00:04", .ghz6, 37, -60, base + sae)], connected: nil)
        try expect(mixed.first?.detail.contains("offre déjà WPA3") == true, "SAE ailleurs sur le même SSID")
        // Sans autorisation de localisation, pas de balise : aucun constat tiré des balises.
        let blind = list.map { network -> WifiNetwork in var copy = network; copy.beacon = nil; copy.bssid = nil; return copy }
        try expect(WifiBeaconAdvisor.recommendations(networks: blind, connected: nil).isEmpty, "aucun constat sans balise")
        // Intégration dans les recommandations de l'analyseur, typographie française.
        let all = WifiAdvisor.recommendations(networks: busy + list, connected: nil)
        try expect(all.contains { $0.id.hasPrefix("sature-") }, "constats dans l'analyseur")
        for reco in all + recos {
            try expect(!reco.title.contains(" :") && !reco.detail.contains(" :") && !reco.detail.contains(" %"),
                       "espace insécable : \(reco.title)")
        }
    }
}

/// Positions où un élément se termine exactement (une coupure là n'est pas une troncature).
private func elementBoundaries(_ bytes: [UInt8]) -> [Int] {
    var result = [0]
    var index = 0
    while index + 2 <= bytes.count {
        index += 2 + Int(bytes[index + 1])
        if index <= bytes.count { result.append(index) }
    }
    return result
}
