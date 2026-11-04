import Foundation

// Note 27 : lecture tolérante des réponses Wi-Fi de FortiOS (6.4 à 7.6). Mêmes principes que
// FortiParsers : enveloppe « results » ou réponse nue, plusieurs noms de champ (« oper_chan »,
// « oper-chan », « channel »), champs absents acceptés, liste ou dictionnaire indexé.
//
// Noms relevés dans la documentation publique de FortiOS (FNDN, guides FortiWiFi et FortiAP),
// le module Ansible fortios_monitor_fact, l'exportateur Prometheus « fortigate_exporter »
// (wifi/managed_ap : radio_id, oper_chan, oper_txpower, client_count,
// channel_utilization_percent, interfering_aps ; wifi/client : mac, signal, noise,
// data_rate_bps, wtp_name, hostname) et la CLI « diagnose wireless-controller wlac ». Ce qui
// n'est pas documenté est lu de façon défensive et gardé dans la réponse brute.

public enum FortiWifiParsers {
    // MARK: Petites conversions

    /// Bande d'après le texte de FortiOS (« 802.11ax-5G », « 11ax-6G », « 2.4GHz », « 5G »), sinon
    /// d'après le canal (1 à 14 : 2,4 GHz, au-delà : 5 GHz ; le 6 GHz ne se devine pas au canal).
    public static func band(_ text: String?, channel: Int?) -> WifiBand? {
        if let raw = text?.lowercased().replacingOccurrences(of: " ", with: ""), !raw.isEmpty {
            if raw.contains("6g") || raw.contains("6e") || raw.contains("6ghz") || raw == "6" { return .ghz6 }
            // « 802.11ac-2G », « 11ac-2g » (radio 2,4 GHz en VHT, FortiOS 6.2 et plus) : avant le test « 11ac ».
            if raw.contains("-2g") || raw.contains("2g") || raw.contains("2.4") || raw.contains("2,4") { return .ghz24 }
            if raw.contains("5g") || raw.contains("5ghz") || raw.contains("11ac") || raw.contains("11a,") || raw.hasSuffix("11a")
                || raw == "5" || raw.contains("11an") || raw.contains("-5") { return .ghz5 }
            if raw.contains("2.4") || raw.contains("2,4") || raw.contains("2g") || raw.contains("11g") || raw.contains("11b")
                || raw.contains("11ng") || raw.contains(",g") || raw.contains("g-only") || raw.contains("bgn") || raw == "2" || raw.contains("-2") { return .ghz24 }
        }
        guard let channel, channel > 0 else { return nil }
        return channel <= 14 ? .ghz24 : .ghz5
    }

    /// Largeur en MHz : 80, « 80MHz », « 80 MHz », « HT40 », « VHT80 », « 160MHz ».
    public static func width(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, !(value is Bool) {
            let v = n.intValue
            return [20, 40, 80, 160, 240, 320].contains(v) ? v : nil
        }
        guard let text = FortiJSON.string(value)?.lowercased() else { return nil }
        let digits = text.filter(\.isNumber)
        guard let v = Int(digits), [20, 40, 80, 160, 240, 320].contains(v) else { return nil }
        return v
    }

    /// Signal en dBm : -58, « -58 », « -58dBm ». Une valeur positive (certaines versions donnent
    /// la force sans signe) est ramenée en négatif ; 0 ou aberrant : nil.
    public static func dbm(_ value: Any?) -> Int? {
        guard let d = FortiJSON.double(value), d.isFinite, d != 0 else { return nil }
        let v = d > 0 ? -d : d
        guard v >= -120, v <= -1 else { return nil }
        return Int(v.rounded())
    }

    /// Pourcentage 0…100 (« 42 », « 42% ») ; au-delà de 100, ramené à 100.
    static func percent(_ value: Any?) -> Double? {
        guard let d = FortiJSON.double(value), d.isFinite, d >= 0 else { return nil }
        return min(d, 100)
    }

    /// Modèle « FAP-231F » tiré du modèle donné (« FP231F », « FAP231F », « FortiAP-231F ») ou du
    /// numéro de série (« FP231FTF20000001 », « FP23JFTF… »).
    public static func apModel(_ text: String?, serial: String) -> String {
        if let raw = text?.uppercased().replacingOccurrences(of: " ", with: ""), !raw.isEmpty {
            var core = raw
            for prefix in ["FORTIAP-", "FORTIAP", "FAP-", "FAP", "FP-", "FP"] where core.hasPrefix(prefix) {
                core = String(core.dropFirst(prefix.count))
                break
            }
            if let code = modelCode(core) { return "FAP-" + code }
            return raw
        }
        let s = serial.uppercased()
        guard s.hasPrefix("FP") || s.hasPrefix("PS") || s.hasPrefix("FAP") else { return "" }
        let body = s.hasPrefix("FAP") ? String(s.dropFirst(3)) : String(s.dropFirst(2))
        return modelCode(body).map { "FAP-" + $0 } ?? ""
    }

    /// « 231F », « 23JF », « 431FTF2… » → « 431F », « U431F » : chiffres puis lettres du modèle.
    static func modelCode(_ text: String) -> String? {
        let chars = Array(text)
        var i = 0
        var code = ""
        if i < chars.count, chars[i] == "U" || chars[i] == "C" || chars[i] == "S" {
            code.append(chars[i])
            i += 1
        }
        let digitsStart = i
        while i < chars.count, chars[i].isNumber, i - digitsStart < 3 { code.append(chars[i]); i += 1 }
        guard i - digitsStart >= 2 else { return nil }
        // Une ou deux lettres de génération (« F », « G », « JF », « K »).
        var letters = 0
        while i < chars.count, chars[i].isLetter, letters < 2 {
            // « FTF » (fin du modèle dans un numéro de série) : on garde la première lettre seule.
            if letters == 1, i + 1 < chars.count, chars[i + 1].isLetter, chars[i] == "T" { break }
            if letters == 1, chars[i] == "T" { break }
            code.append(chars[i])
            letters += 1
            i += 1
        }
        guard letters > 0 else { return nil }
        return code
    }

    /// Durée en secondes : nombre, ou texte « 3d 4h 12m », « 01:02:03 ».
    static func duration(_ value: Any?) -> TimeInterval? {
        if let n = value as? NSNumber, !(value is Bool) {
            let d = n.doubleValue
            return d.isFinite && d >= 0 ? d : nil
        }
        guard let text = FortiJSON.string(value)?.lowercased() else { return nil }
        if let d = Double(text), d >= 0 { return d }
        let colon = text.split(separator: ":").compactMap { Double($0) }
        if colon.count == 3, text.filter({ $0 == ":" }).count == 2 { return colon[0] * 3600 + colon[1] * 60 + colon[2] }
        var total: Double = 0
        var found = false
        let pattern = #"(\d+)\s*(d|j|h|m|s)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let n = Range(match.range(at: 1), in: text).flatMap({ Double(text[$0]) }),
                      let u = Range(match.range(at: 2), in: text).map({ text[$0] }) else { continue }
                found = true
                switch u {
                case "d", "j": total += n * 86_400
                case "h": total += n * 3600
                case "m": total += n * 60
                default: total += n
                }
            }
        }
        return found ? total : nil
    }

    /// État de connexion d'une borne : « connected », « Connected », « online », « disconnected »,
    /// « offline », « down », « discovered » (jamais connectée).
    static func connected(_ item: FortiObject) -> Bool? {
        let texts = [item.string("status"), item.string("connection_state", "connection-state", "connectionstate", "state_connection"),
                     item.string("state")].compactMap { $0?.lowercased() }
        for s in texts {
            if s.contains("disconn") || s.contains("offline") || s == "down" || s.contains("lost") || s.contains("unreach") { return false }
        }
        for s in texts {
            if s.contains("connected") || s.contains("online") || s == "up" || s.contains("run") { return true }
        }
        if let b = item.bool("is_connected", "connected", "online", "up") { return b }
        // Borne découverte mais pas autorisée : elle ne sert personne.
        if texts.contains(where: { $0.contains("discover") || $0.contains("idle") }) { return false }
        return nil
    }

    // MARK: Bornes

    /// /api/v2/monitor/wifi/managed_ap : liste des bornes, ou dictionnaire indexé par série.
    public static func managedAPs(_ data: Data, now: Date = Date()) -> [FortiManagedAP]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let items = FortiJSON.objects(FortiJSON.results(json))
        if items.isEmpty { return (json is [String: Any] || json is [Any]) ? [] : nil }
        return items.compactMap { managedAP($0, now: now) }
    }

    static func managedAP(_ item: FortiObject, now: Date) -> FortiManagedAP? {
        let serial = item.string("serial", "sn", "serial_number", "wtp_serial", "board_serial") ?? ""
        let wtpID = item.string("wtp_id", "wtp-id", "wtpid", "id", "_key") ?? serial
        let name = item.string("name", "wtp_name", "wtp-name", "ap_name", "hostname") ?? ""
        guard !(serial.isEmpty && wtpID.isEmpty && name.isEmpty) else { return nil }
        let firmware = item.string("os_version", "os-version", "firmware_version", "firmware", "version", "software_version") ?? ""
        var model = apModel(item.string("model", "model_name", "platform", "wtp_model", "ap_model", "board_model"),
                            serial: serial.isEmpty ? wtpID : serial)
        if model.isEmpty, let code = firmware.split(separator: "-").first.map(String.init) { model = apModel(code, serial: "") }
        let ip = FortiParse.ipv4(item.any("connecting_from", "connecting-from", "local_ipv4_addr", "ip", "ip_address", "ipv4_address",
                                          "wtp_ip", "local_ip", "mgmt_ip"))
        let radios = item.list("radio", "radios", "radio_info").enumerated().compactMap { offset, r in radio(r, fallbackID: offset + 1) }
        var uptime = duration(item.any("uptime", "up_time", "connection_uptime", "join_time_duration"))
        if uptime == nil, let joined = item.double("join_time_raw", "join-time-raw", "join_time_epoch"), joined > 1_000_000_000 {
            uptime = max(0, now.timeIntervalSince1970 - (joined > 1_000_000_000_000 ? joined / 1000 : joined))
        }
        let clients = item.int("clients", "client_count", "sta_count", "station_count", "wifi_client_count", "total_clients")
        let lastSeen = FortiParse.lastSeen(item.any("last_seen", "last-seen", "last_failure_time", "last_reboot_time"), now: now)
        let admin = item.string("admin", "authorization", "state", "auth_status")
        return FortiManagedAP(name: name, wtpID: wtpID, serial: serial, model: model, firmware: firmware, ip: ip,
                              connected: connected(item), state: item.string("status", "connection_state", "connection-state"),
                              admin: admin, uptime: uptime, profile: item.string("ap_profile", "wtp_profile", "wtp-profile", "profile"),
                              clientCount: clients, radios: radios, lastSeen: lastSeen,
                              location: item.string("location", "loc", "description"))
    }

    static func radio(_ item: FortiObject, fallbackID: Int) -> FortiAPRadio? {
        let id = item.int("radio_id", "radio-id", "radioid", "id", "index") ?? fallbackID
        let channel = item.int("oper_chan", "oper-chan", "operating_channel", "channel", "oper_channel", "current_channel")
            .flatMap { $0 > 0 ? $0 : nil }
        let bandText = item.string("radio_type", "radio-type", "band", "frequency_band", "phy_mode", "mode_type", "oper_band")
        let mode = item.string("mode", "radio_mode", "operating_mode")
        // Radio sans aucune donnée utile (emplacement vide d'une borne mono-radio).
        if channel == nil, bandText == nil, mode == nil, item.int("client_count", "clients") == nil { return nil }
        let txDBm = item.int("oper_txpower", "oper-txpower", "tx_power_dbm", "txpower_dbm", "power_dbm")
        let txPercent = item.int("txpower", "tx_power", "power_level", "txpower_percent")
        return FortiAPRadio(radioID: id, band: band(bandText, channel: channel), channel: channel,
                            widthMHz: width(item.any("channel_bandwidth", "channel-bandwidth", "bandwidth", "chan_width", "channel_width", "width")),
                            txPowerDBm: txDBm.flatMap { (0...40).contains($0) ? $0 : nil },
                            txPowerPercent: txDBm == nil ? txPercent.flatMap { (0...100).contains($0) ? $0 : nil } : nil,
                            clientCount: item.int("client_count", "clients", "sta_count", "station_count"),
                            channelUtilization: percent(item.any("channel_utilization_percent", "channel_utilization", "chan_util",
                                                                 "channel-utilization", "utilization")),
                            noiseDBm: dbm(item.any("noise_floor", "noise-floor", "noise", "noisefloor")),
                            interferingAPs: item.int("interfering_aps", "interfering-aps", "interfering_ap_count"),
                            mode: mode, standard: bandText)
    }

    // MARK: Clients

    /// /api/v2/monitor/wifi/client.
    public static func clients(_ data: Data, now: Date = Date()) -> [FortiWifiClient]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let items = FortiJSON.objects(FortiJSON.results(json))
        if items.isEmpty { return (json is [String: Any] || json is [Any]) ? [] : nil }
        return items.compactMap { client($0, now: now) }
    }

    static func client(_ item: FortiObject, now: Date = Date()) -> FortiWifiClient? {
        guard let mac = FortiParse.mac(item.any("mac", "mac_address", "sta_mac", "client_mac", "_key")) else { return nil }
        let channel = item.int("channel", "chan", "oper_chan").flatMap { $0 > 0 ? $0 : nil }
        let rssi = dbm(item.any("signal", "rssi", "signal_strength", "signal-strength"))
        let noise = dbm(item.any("noise", "noise_floor", "signal_noise"))
        var rate: Double?
        if let bps = item.double("data_rate_bps", "data-rate-bps"), bps > 0 {
            rate = bps / 1_000_000
        } else if let mbps = item.double("data_rate", "data-rate", "tx_rate", "rate", "phy_rate", "link_rate"), mbps > 0 {
            // Valeur en kb/s chez certaines versions (« 866700 »).
            rate = mbps > 20_000 ? mbps / 1000 : mbps
        }
        let snr = item.int("snr", "signal_to_noise", "snr_db")
        var associated = duration(item.any("association_time", "assoc_time", "associated_time", "duration", "online_time", "uptime"))
        // Certaines versions donnent l'heure d'association (horodatage) au lieu d'une durée.
        if let a = associated, a > 1_000_000_000 { associated = max(0, now.timeIntervalSince1970 - a) }
        let apName = item.string("wtp_name", "wtp-name", "ap_name", "ap", "wtp")
        let apKey = item.string("wtp_id", "wtp-id", "wtp_serial", "serial", "ap_serial") ?? apName
        let bandText = item.string("radio_type", "band", "radio-type", "frequency_band")
        return FortiWifiClient(mac: mac, ip: FortiParse.ipv4(item.any("ip", "ipv4", "ip_address", "ipv4_address", "ip_addr")),
                               hostname: item.string("hostname", "host", "host_name", "name", "user", "device_name"),
                               ssid: item.string("ssid", "vap_ssid", "wlan", "vap_name", "vap"),
                               apName: apName, apKey: apKey, radioID: item.int("radio_id", "radio-id", "radio"),
                               band: band(bandText, channel: channel), channel: channel, rssi: rssi, noise: noise,
                               snr: snr.flatMap { (0...90).contains($0) ? $0 : nil },
                               rateMbps: rate.flatMap { $0 < 100_000 ? $0 : nil }, associatedFor: associated,
                               os: item.string("os", "os_name", "device_os", "os_version", "type", "device_type"),
                               vlan: item.int("vlan_id", "vlanid", "vlan").flatMap { (1...4094).contains($0) ? $0 : nil },
                               manufacturer: item.string("manufacturer", "vendor", "hardware_vendor"))
    }

    // MARK: SSID

    /// /api/v2/cmdb/wireless-controller/vap : interfaces SSID.
    public static func ssids(_ data: Data) -> [FortiSSID]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let items = FortiJSON.objects(FortiJSON.results(json))
        if items.isEmpty { return (json is [String: Any] || json is [Any]) ? [] : nil }
        return items.compactMap { item in
            let name = item.string("name", "_key", "vap_name") ?? ""
            let ssid = item.string("ssid", "ssid_name") ?? name
            guard !ssid.isEmpty else { return nil }
            let security = item.string("security", "security-mode", "security_mode", "auth", "encryption")
            let portal = item.string("portal-type", "portal_type", "security-exempt-list").map { !$0.isEmpty }
                ?? (security?.lowercased().contains("captive") == true ? true : nil)
            let broadcast = item.bool("broadcast-ssid", "broadcast_ssid", "broadcastssid")
            return FortiSSID(name: name, ssid: ssid, security: security,
                             vlan: item.int("vlanid", "vlan-id", "vlan_id", "vlan").flatMap { (1...4094).contains($0) ? $0 : nil },
                             hidden: broadcast.map { !$0 }, localBridging: item.bool("local-bridging", "local_bridging"),
                             maxClients: item.int("max-clients", "max_clients").flatMap { $0 > 0 ? $0 : nil }, captivePortal: portal)
        }
    }

    // MARK: AP voisins et non autorisés

    /// /api/v2/monitor/wifi/rogue_ap ou /interfering_ap : un AP par BSSID ; les entrées du même
    /// BSSID vues par plusieurs bornes sont regroupées (signal le plus fort, liste des bornes).
    public static func rogues(_ data: Data, now: Date = Date()) -> [FortiRogueAP]? {
        guard let json = FortiJSON.parse(data) else { return nil }
        let items = FortiJSON.objects(FortiJSON.results(json))
        if items.isEmpty { return (json is [String: Any] || json is [Any]) ? [] : nil }
        var result: [FortiRogueAP] = []
        for item in items {
            // Forme regroupée par borne : { "wtp": "FP231F…", "interfering_ap": [ … ] }.
            let nested = item.list("interfering_ap", "interfering_aps", "rogue_ap", "aps", "neighbors")
            if !nested.isEmpty {
                let by = item.string("wtp_name", "wtp", "wtp_id", "name", "_key")
                for child in nested { if let ap = rogue(child, now: now, seenBy: by) { merge(ap, into: &result) } }
            } else if let ap = rogue(item, now: now, seenBy: nil) {
                merge(ap, into: &result)
            }
        }
        return result
    }

    static func merge(_ ap: FortiRogueAP, into list: inout [FortiRogueAP]) {
        guard let bssid = ap.bssid, let index = list.firstIndex(where: { $0.bssid == bssid }) else {
            list.append(ap)
            return
        }
        var current = list[index]
        if let r = ap.rssi, r > (current.rssi ?? -200) { current.rssi = r }
        for name in ap.seenBy where !current.seenBy.contains(name) { current.seenBy.append(name) }
        if ap.isUnauthorized { current.status = ap.status == .rogue ? .rogue : current.status }
        current.onWire = current.onWire || ap.onWire
        list[index] = current
    }

    static func rogue(_ item: FortiObject, now: Date, seenBy: String?) -> FortiRogueAP? {
        let bssid = FortiParse.mac(item.any("bssid", "mac", "bss_id", "ap_mac", "_key"))
        let ssid = item.string("ssid", "ssid_name", "essid")
        guard bssid != nil || ssid != nil else { return nil }
        let channel = item.int("channel", "chan", "oper_chan").flatMap { $0 > 0 ? $0 : nil }
        let statusText = (item.string("status", "classification", "state", "ap_status") ?? "").lowercased()
        var status: FortiRogueAP.Status = .unclassified
        if statusText.contains("rogue") || statusText.contains("unauthor") { status = .rogue }
        else if statusText.contains("accept") || statusText.contains("authorized") { status = .accepted }
        else if statusText.contains("suppress") || statusText.contains("contain") { status = .suppressed }
        let onWire = item.bool("is_on_wire", "on_wire", "onwire", "on-wire", "wired") ?? false
        var seen: [String] = []
        if let seenBy { seen.append(seenBy) }
        for name in [item.string("detected_by", "detected-by", "detected_by_wtp", "wtp_name", "wtp_id", "wtp", "seen_by")].compactMap({ $0 })
        where !seen.contains(name) { seen.append(name) }
        for child in item.list("detected_by", "wtps", "seen_by_wtps") {
            if let n = child.string("wtp_name", "name", "wtp_id", "wtp"), !seen.contains(n) { seen.append(n) }
        }
        return FortiRogueAP(ssid: ssid, bssid: bssid, channel: channel,
                            band: band(item.string("band", "radio_type", "radio_band"), channel: channel),
                            rssi: dbm(item.any("signal_strength", "signal", "rssi", "sta_signal", "max_signal")),
                            status: status, onWire: onWire, seenBy: seen,
                            security: item.string("security_mode", "security", "encryption", "encrypt"),
                            vendor: item.string("manufacturer", "vendor", "oui_vendor"),
                            lastSeen: FortiParse.lastSeen(item.any("last_seen", "last-seen", "lastseen"), now: now))
    }
}
