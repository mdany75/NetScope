import Foundation

// Note 47 : diagnostic d'une borne entière (toutes ses radios, ses clients, son lien vers le
// switch) et d'un SSID entier (ses clients sur toutes les bornes du site). Mêmes causes, mêmes
// verdicts et même présentation que pour un client ; fonctions pures.

extension WifiDiagnosis {
    // MARK: Borne

    /// Diagnostic d'une borne : `overview` donne les autres bornes, les voisins et les clients du site.
    public static func diagnose(ap: FortiManagedAP, overview: FortiWifiOverview, measures: WifiDiagnosisMeasures = .none,
                                thresholds t: WifiDiagnosisThresholds = .standard, now: Date = Date(), id: UUID = UUID()) -> WifiDiagnosisResult {
        let siteAPs = overview.aps.filter { $0.site == ap.site }
        let neighbors = overview.rogues.filter { $0.site == ap.site }
        let clients = overview.clients(of: ap)
        var causes: [WifiCauseResult] = []
        let radios = ap.radios.filter(\.isServing)
        if ap.isOffline {
            var evidence = ["\(ap.name)" + (ap.model.isEmpty ? "" : " (\(ap.model))") + " ne répond plus à la FortiGate"]
            if let ip = ap.ip { evidence.append("Dernière adresse \(ip)") }
            if let seen = ap.lastSeen { evidence.append("Vue il y a \(minutes(now.timeIntervalSince(seen)))") }
            var actions = ["Vérifier l’alimentation PoE et le câble de \(ap.name) (port du switch, prise murale).",
                           "Contrôler son état dans WiFi & Switch Controller › Managed FortiAPs (autorisation, profil)."]
            if let u = measures.uplink { actions.insert("Commencer par le port \(u.label).", at: 0) }
            causes.append(WifiCauseResult(cause: .uplink, verdict: .problem, summary: "La borne est hors ligne\(nb): ses clients sont passés ailleurs ou n’ont plus de Wi-Fi.",
                                          evidence: evidence, actions: actions, weight: 1))
        } else {
            causes.append(uplink(measures, t))
        }
        if !ap.isOffline && !radios.isEmpty {
            causes.append(merge(.channel, radios.map { channelResult(radio: $0, ap: ap, siteAPs: siteAPs, neighbors: neighbors, t) }))
            causes.append(merge(.interference, radios.map { interferenceResult(radio: $0, ap: ap, siteAPs: siteAPs, neighbors: neighbors, t) }))
            causes.append(merge(.width, radios.map { widthResult(radio: $0, ap: ap, siteAPs: siteAPs) }))
            causes.append(merge(.dfs, radios.filter { $0.band == .ghz5 }.map { dfsResult(radio: $0, ap: ap, changes: measures.dfsChannelChanges) }))
            causes.append(merge(.load, radios.map { loadResult(radio: $0, ap: ap, clients: clients, t) }))
            causes.append(merge(.slowClients, radios.map { slowResult(radio: $0, ap: ap, clients: clients, t) }))
            causes.append(groupSignal(clients, where: "sur \(ap.name)", t))
            causes.append(groupBand(clients, has5: ap.radio(.ghz5) != nil || ap.radio(.ghz6) != nil, t))
        } else if !ap.isOffline {
            causes.append(WifiCauseResult(cause: .channel, verdict: .watch, summary: "Aucune radio n’émet\(nb): radios éteintes ou en mode moniteur.",
                                          evidence: ap.radios.map { "Radio \($0.radioID)\(nb): \($0.mode ?? "éteinte")" },
                                          actions: ["Vérifier le profil FortiAP de \(ap.name)\(nb): au moins une radio en mode «\(nb)AP\(nb)»."], weight: 0.5))
        }
        causes.append(network(measures, t))
        if !measures.wan.isEmpty { causes.append(wan(measures, t)) }
        causes = order(causes.filter { !($0.verdict == .notMeasured && $0.evidence.isEmpty && $0.cause == .dfs) })
        let parts: [String?] = [ap.name, ap.model.isEmpty ? nil : ap.model, ap.ip?.description,
                                radios.isEmpty ? nil : radios.map(radioLabel).joined(separator: " · "), plural(clients.count, "client", "clients")]
        let context = parts.compactMap { $0 }
        var notes: [String] = []
        if measures.paths.isEmpty { notes.append("Mesures de ping non faites\(nb): passerelle, DNS et Internet non vérifiés.") }
        return WifiDiagnosisResult(id: id, subject: .ap(name: ap.name), site: ap.site, date: now, context: context.joined(separator: " · "),
                                   causes: causes, actions: actions(causes), measured: !measures.paths.isEmpty, notes: notes)
    }

    /// Plusieurs radios d'une même cause : le pire verdict, les preuves de toutes, les actions des radios en cause.
    static func merge(_ cause: WifiCause, _ results: [WifiCauseResult]) -> WifiCauseResult {
        guard !results.isEmpty else {
            return WifiCauseResult(cause: cause, verdict: .ok, summary: cause == .dfs ? "Aucune radio 5\(nb)GHz\(nb): sans objet." : "Sans objet.")
        }
        let worst = results.max { ($0.verdict, $0.weight) < ($1.verdict, $1.weight) }!
        var seen = Set<String>()
        var actions: [String] = []
        for r in results.sorted(by: { ($0.verdict, $0.weight) > ($1.verdict, $1.weight) }) where r.verdict >= .watch {
            for a in r.actions where seen.insert(a).inserted { actions.append(a) }
        }
        var evidenceSeen = Set<String>()
        let evidence = results.flatMap(\.evidence).filter { evidenceSeen.insert($0).inserted }
        return WifiCauseResult(cause: cause, verdict: worst.verdict, summary: worst.summary, evidence: evidence, actions: actions, weight: worst.weight)
    }

    /// Signal d'un groupe de clients (borne, SSID) : part des clients faibles.
    static func groupSignal(_ clients: [FortiWifiClient], where place: String, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let measured = clients.filter { $0.rssi != nil || $0.snr != nil }
        guard !measured.isEmpty else {
            return WifiCauseResult(cause: .signal, verdict: clients.isEmpty ? .ok : .notMeasured,
                                   summary: clients.isEmpty ? "Aucun client associé." : "Signal des clients non donné.")
        }
        func weak(_ c: FortiWifiClient) -> Bool { (c.rssi.map { $0 < t.weakRSSI } ?? false) || (c.snr.map { $0 < t.weakSNR } ?? false) }
        func bad(_ c: FortiWifiClient) -> Bool { (c.rssi.map { $0 < t.badRSSI } ?? false) || (c.snr.map { $0 < t.badSNR } ?? false) }
        let weakOnes = measured.filter(weak).sorted { ($0.rssi ?? 0) < ($1.rssi ?? 0) }
        let badOnes = measured.filter(bad)
        let share = Double(weakOnes.count) / Double(measured.count)
        var evidence = ["\(weakOnes.count) client\(weakOnes.count > 1 ? "s" : "") sur \(measured.count) sous \(dbm(t.weakRSSI)) ou \(db(t.weakSNR)) de SNR \(place)"]
        if !weakOnes.isEmpty {
            evidence.append("Les plus faibles\(nb): " + weakOnes.prefix(3).map { c in "\(c.displayName) (\(c.rssi.map(dbm) ?? c.snr.map { "SNR " + db($0) } ?? "—"))" }.joined(separator: ", "))
        }
        let actions = ["Vérifier la couverture là où sont les clients faibles (relevé Wi-Fi), puis rapprocher ou ajouter une borne.",
                       "Activer 802.11k/v et un seuil de RSSI minimal pour que les clients changent de borne à temps."]
        if share >= 0.3 && weakOnes.count >= 3 || badOnes.count >= 3 {
            return WifiCauseResult(cause: .signal, verdict: .problem, summary: "Beaucoup de clients ont un signal faible\(nb): la couverture est insuffisante.",
                                   evidence: evidence, actions: actions, weight: 0.5 + share / 2)
        }
        if !weakOnes.isEmpty {
            return WifiCauseResult(cause: .signal, verdict: .watch, summary: "Quelques clients ont un signal faible.", evidence: evidence,
                                   actions: Array(actions.prefix(1)), weight: share)
        }
        return WifiCauseResult(cause: .signal, verdict: .ok, summary: "Tous les clients ont un bon signal.", evidence: evidence)
    }

    /// Clients en 2,4 GHz alors que le 5 GHz est disponible.
    static func groupBand(_ clients: [FortiWifiClient], has5: Bool, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        let banded = clients.filter { $0.band != nil }
        guard !banded.isEmpty else {
            return WifiCauseResult(cause: .band, verdict: .ok, summary: clients.isEmpty ? "Aucun client associé." : "Bande des clients non donnée.")
        }
        let on24 = banded.filter { $0.band == .ghz24 }
        let share = Double(on24.count) / Double(banded.count)
        let evidence = ["\(on24.count) client\(on24.count > 1 ? "s" : "") sur \(banded.count) en 2,4\(nb)GHz"]
        guard has5 else {
            return WifiCauseResult(cause: .band, verdict: .ok, summary: "Pas de 5\(nb)GHz disponible ici.", evidence: evidence)
        }
        if share > 0.5 && on24.count >= 3 {
            return WifiCauseResult(cause: .band, verdict: .watch, summary: "La plupart des clients restent en 2,4\(nb)GHz alors que le 5\(nb)GHz est disponible.",
                                   evidence: evidence, actions: ["Activer le pilotage de bande (band steering, «\(nb)Prefer 5 GHz\(nb)») sur les SSID."], weight: share / 2)
        }
        return WifiCauseResult(cause: .band, verdict: .ok, summary: "Répartition des bandes correcte.", evidence: evidence)
    }

    // MARK: SSID

    /// Diagnostic d'un SSID sur un site : ses clients, les bornes qui le servent, ses limites et
    /// les faux SSID du même nom (jumeau malveillant).
    public static func diagnose(ssid: FortiSSID, overview: FortiWifiOverview, measures: WifiDiagnosisMeasures = .none,
                                thresholds t: WifiDiagnosisThresholds = .standard, now: Date = Date(), id: UUID = UUID()) -> WifiDiagnosisResult {
        let site = ssid.site
        let clients = overview.clients.filter { $0.site == site && $0.ssid == ssid.ssid }
        let siteAPs = overview.aps.filter { $0.site == site }
        let serving = siteAPs.filter { ap in clients.contains { overview.ap(for: $0)?.id == ap.id } }
        let neighbors = overview.rogues.filter { $0.site == site }
        var causes: [WifiCauseResult] = []
        causes.append(groupSignal(clients, where: "sur \(quoted(ssid.ssid))", t))
        causes.append(groupBand(clients, has5: serving.contains { $0.radio(.ghz5) != nil || $0.radio(.ghz6) != nil }, t))

        // Charge et canaux des bornes qui servent ce SSID.
        let overloads = FortiWifiAnalysis.overloaded(serving, clients: overview.clients, thresholds: FortiWifiThresholds(
            weakRSSI: t.weakRSSI, weakSNR: t.weakSNR, maxClientsPerRadio: t.maxClientsPerRadio, maxChannelUtilization: t.saturatedUtilization))
        if serving.isEmpty {
            causes.append(WifiCauseResult(cause: .load, verdict: .ok, summary: "Aucun client associé à ce SSID."))
        } else if overloads.isEmpty {
            causes.append(WifiCauseResult(cause: .load, verdict: .ok, summary: "Aucune borne surchargée parmi celles qui servent ce SSID.",
                                          evidence: ["Servi par \(serving.prefix(4).map(\.name).joined(separator: ", "))\(serving.count > 4 ? "…" : "")"]))
        } else {
            let evidence = overloads.map { o -> String in
                var parts: [String] = []
                if o.tooManyClients { parts.append("\(o.radio.clientCount ?? 0) clients") }
                if o.busyChannel, let u = o.radio.channelUtilization { parts.append("canal occupé à \(pct(u))") }
                return "\(o.apName) \(radioLabel(o.radio))\(nb): " + parts.joined(separator: ", ")
            }
            causes.append(WifiCauseResult(cause: .load, verdict: .problem, summary: "Des bornes qui servent ce SSID sont surchargées.", evidence: evidence,
                                          actions: ["Activer l’équilibrage de charge (Frequency Handoff et AP Handoff) et ajouter une borne près de \(overloads[0].apName)."],
                                          weight: 0.6))
        }
        let overlaps = FortiWifiAnalysis.channelOverlaps(siteAPs).filter { o in serving.contains { $0.name == o.first || $0.name == o.second } }
        if serving.isEmpty {
            causes.append(WifiCauseResult(cause: .channel, verdict: .notMeasured, summary: "Aucune borne ne sert ce SSID en ce moment."))
        } else if overlaps.isEmpty {
            causes.append(WifiCauseResult(cause: .channel, verdict: .ok, summary: "Les bornes de ce SSID ne se chevauchent pas."))
        } else {
            let partial = overlaps.contains { $0.kind == .adjacent }
            causes.append(WifiCauseResult(cause: .channel, verdict: partial ? .problem : .watch,
                                          summary: "\(plural(overlaps.count, "chevauchement", "chevauchements")) de canal entre les bornes de ce SSID.",
                                          evidence: overlaps.prefix(4).map { "\($0.kindLabel)\(nb): \($0.pairLabel)" },
                                          actions: ["Établir un plan de canaux (DARRP ou canaux fixés) pour que deux bornes voisines n’aient jamais le même bloc."],
                                          weight: partial ? 0.6 : 0.35))
        }
        // Jumeau malveillant : un AP non géré diffuse le même nom.
        let twins = neighbors.filter { $0.ssid == ssid.ssid }
        if twins.isEmpty {
            causes.append(WifiCauseResult(cause: .interference, verdict: .ok, summary: "Aucun autre AP ne diffuse ce nom de réseau."))
        } else {
            let evidence = twins.prefix(3).map { r -> String in
                "\(r.bssid?.formatted(.upperColon) ?? "BSSID inconnu")" + (r.channel.map { " canal \($0)" } ?? "") + (r.rssi.map { " à \(dbm($0))" } ?? "")
                    + (r.vendor.map { " (\($0))" } ?? "")
            }
            causes.append(WifiCauseResult(cause: .interference, verdict: .problem,
                                          summary: "Un point d’accès étranger diffuse le même nom \(quoted(ssid.ssid))\(nb): des clients peuvent s’y connecter par erreur.",
                                          evidence: evidence, actions: ["Localiser et retirer l’AP qui imite \(quoted(ssid.ssid))\(nb); le déclarer non autorisé et activer la protection WIDS."],
                                          weight: 0.9))
        }
        // Clients lents du SSID.
        let rated = clients.filter { $0.rateMbps != nil }
        let slow = rated.filter { ($0.rateMbps ?? 0) < t.lowRateMbps }
        if rated.count >= 2 {
            let share = Double(slow.count) / Double(rated.count)
            let verdict: WifiVerdict = share >= t.slowShare ? .watch : .ok
            causes.append(WifiCauseResult(cause: .slowClients, verdict: verdict,
                                          summary: verdict == .ok ? "Peu de clients lents." : "Une bonne part des clients du SSID négocie un débit bas.",
                                          evidence: ["\(slow.count) client\(slow.count > 1 ? "s" : "") sur \(rated.count) sous \(rate(t.lowRateMbps))"],
                                          actions: verdict == .ok ? [] : ["Retirer les débits de base anciens sur \(quoted(ssid.ssid))\(nb): débit minimal de 12 ou 24\(nb)Mb/s."],
                                          weight: share / 2))
        }
        // Limites et sécurité du SSID.
        var limits = ssidLimits(WifiDiagnosisInput(client: FortiWifiClient(mac: MACAddress(bytes: [0, 0, 0, 0, 0, 0])), ssid: ssid,
                                                   ssidClientCount: clients.count), t)
        if ssid.isOpen && limits.verdict < .watch {
            limits.verdict = .watch
            limits.summary = "Réseau sans chiffrement\(nb): sans effet sur le débit, mais le trafic circule en clair."
            limits.actions = ["Passer \(quoted(ssid.ssid)) en WPA2/WPA3 ou en OWE (Enhanced Open), et isoler ce réseau du LAN."]
            limits.weight = 0.2
        }
        causes.append(limits)
        causes.append(dhcpGroup(measures, ssid: ssid, t))
        causes.append(network(measures, t))
        if !measures.wan.isEmpty { causes.append(wan(measures, t)) }
        causes = order(causes)
        let parts: [String?] = [quoted(ssid.ssid), ssid.securityLabel, ssid.vlan.map { "VLAN \($0)" }, plural(clients.count, "client", "clients"),
                                serving.isEmpty ? nil : plural(serving.count, "borne", "bornes")]
        let context = parts.compactMap { $0 }
        var notes: [String] = []
        if measures.paths.isEmpty { notes.append("Mesures de ping non faites\(nb): passerelle, DNS et Internet non vérifiés.") }
        return WifiDiagnosisResult(id: id, subject: .ssid(name: ssid.ssid), site: site, date: now, context: context.joined(separator: " · "),
                                   causes: causes, actions: actions(causes), measured: !measures.paths.isEmpty, notes: notes)
    }

    static func dhcpGroup(_ m: WifiDiagnosisMeasures, ssid: FortiSSID, _ t: WifiDiagnosisThresholds) -> WifiCauseResult {
        guard let scope = m.dhcp else {
            return WifiCauseResult(cause: .dhcp, verdict: .notMeasured, summary: "Étendue DHCP du VLAN non lue.")
        }
        let evidence = ["Étendue \(scope.scopeName)\(nb): \(pct(scope.percent)) occupée, \(plural(scope.free, "adresse libre", "adresses libres")) sur \(scope.poolSize)"]
        if scope.critical || scope.free == 0 {
            return WifiCauseResult(cause: .dhcp, verdict: .problem, summary: "L’étendue DHCP du SSID est presque pleine\(nb): les nouveaux clients risquent de ne pas avoir d’adresse.",
                                   evidence: evidence, actions: ["Libérer des adresses dans \(scope.scopeName)\(nb): bail plus court (invités), plage élargie, ou sous-réseau plus grand."], weight: 0.7)
        }
        if scope.warning {
            return WifiCauseResult(cause: .dhcp, verdict: .watch, summary: "L’étendue DHCP du SSID se remplit.", evidence: evidence,
                                   actions: ["Prévoir plus d’adresses dans \(scope.scopeName) (bail plus court ou plage élargie)."], weight: 0.3)
        }
        return WifiCauseResult(cause: .dhcp, verdict: .ok, summary: "Assez d’adresses libres.", evidence: evidence)
    }
}
