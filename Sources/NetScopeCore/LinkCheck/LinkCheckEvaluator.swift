import Foundation

/// Note 58 : verdict de chaque étape du bilan, tiré des mesures (fonctions pures, testées sans réseau).
public enum LinkCheckEvaluator {
    static let nb = "\u{00A0}"

    /// Seuils (latences en millisecondes).
    public enum Threshold {
        /// Latence de la passerelle au-delà de laquelle on avertit, en filaire et en Wi-Fi.
        public static let gatewayWired: Double = 10
        public static let gatewayWireless: Double = 30
        /// Perte de la passerelle à partir de laquelle l'étape échoue (en %).
        public static let gatewayLossFailure: Double = 20
        public static let dhcpSlow: Double = 2
        public static let dnsSlow: Double = 150
        public static let internetSlow: Double = 1000
    }

    static func ms(_ value: Double) -> String { ToolFormat.milliseconds(value) }
    static func percent(_ value: Double) -> String {
        (value == value.rounded() ? String(Int(value)) : ToolFormat.decimal(value)) + "\(nb)%"
    }

    // MARK: Lien

    public static func link(_ link: LinkCheckLink?, requested name: String) -> LinkCheckStep {
        guard let link else {
            return LinkCheckStep(kind: .lien, status: .failure, summary: "Interface introuvable",
                                 explanation: "L’interface \(name) n’existe plus ou n’a pas de lien. Vérifiez l’adaptateur et le câble, puis relancez le bilan.")
        }
        var facts = [LinkCheckFact("interface", "Interface", "\(link.name) · \(link.kindLabel)")]
        if let speed = link.speedMbps {
            facts.append(LinkCheckFact("vitesse", "Vitesse", LinkMedia.speedLabel(speed), number: Double(speed), higherIsBetter: true))
        }
        if let duplex = link.duplex { facts.append(LinkCheckFact("duplex", "Duplex", duplex.shortLabel)) }
        if let media = link.mediaLabel { facts.append(LinkCheckFact("media", "Média", media)) }
        if let address = link.address, address.value != 0 { facts.append(LinkCheckFact("adresse", "Adresse IPv4", address.description)) }

        if link.isActive == false {
            return LinkCheckStep(kind: .lien, status: .failure, summary: "Pas de lien",
                                 explanation: link.isWireless
                                    ? "Le Wi-Fi n’est associé à aucun réseau."
                                    : "Aucune porteuse sur \(link.name)\(nb): câble débranché, prise non brassée ou port de switch désactivé.",
                                 facts: facts)
        }
        var parts: [String] = []
        if let speed = link.speedMbps { parts.append(LinkMedia.speedLabel(speed)) }
        if let duplex = link.duplex { parts.append(duplex.label) }
        if parts.isEmpty { parts.append(link.kindLabel) }
        let summary = parts.joined(separator: " · ")

        if !link.hasUsableAddress {
            let why = link.isLinkLocal
                ? "macOS s’est donné une adresse automatique (169.254.x.x)\(nb): aucun serveur DHCP ne lui a répondu."
                : "L’interface n’a pas d’adresse IPv4."
            return LinkCheckStep(kind: .lien, status: .failure, summary: summary + " · sans adresse",
                                 explanation: why + " Le lien physique est monté\(nb); voyez l’étape DHCP.", facts: facts)
        }
        if link.duplex == .half {
            return LinkCheckStep(kind: .lien, status: .warning, summary: summary,
                                 explanation: "Semi-duplex négocié\(nb): collisions et lenteurs assurées. Le plus souvent, un côté est forcé (vitesse et duplex fixes) et l’autre en autonégociation\(nb); mettez les deux en automatique ou vérifiez le câble.",
                                 facts: facts)
        }
        if !link.isWireless, let speed = link.speedMbps, speed < 1000 {
            return LinkCheckStep(kind: .lien, status: .warning, summary: summary,
                                 explanation: "Lien négocié à \(LinkMedia.speedLabel(speed)) seulement. Une paire coupée ou un câble de catégorie inférieure limite souvent le lien à 100\(nb)Mb/s\(nb); testez le câble et la prise, ou vérifiez la vitesse du port.",
                                 facts: facts)
        }
        let explanation = link.isWireless
            ? "Wi-Fi associé, adresse \(link.address?.description ?? "")." + (link.speedMbps.map { " Débit de liaison \(LinkMedia.speedLabel($0))." } ?? "")
            : "Lien monté" + (link.speedMbps.map { " à \(LinkMedia.speedLabel($0))" } ?? "")
                + (link.duplex == .full ? " en duplex intégral" : "") + ", adresse \(link.address?.description ?? "")."
        return LinkCheckStep(kind: .lien, status: .ok, summary: summary, explanation: explanation, facts: facts)
    }

    // MARK: Switch, VLAN et PoE (annonces LLDP/CDP)

    /// Raison commune d'une étape LLDP non mesurée, ou nil si l'annonce est là.
    private static func neighborGap(_ measure: LinkCheckNeighborMeasure?, link: LinkCheckLink) -> String? {
        if link.isWireless { return "Interface Wi-Fi\(nb): le Mac n’est pas branché sur un port de switch (la borne l’est)." }
        guard let measure else { return "Écoute LLDP/CDP non faite." }
        if measure.neighbor != nil { return nil }
        if let reason = measure.unavailableReason { return reason }
        return nil
    }

    public static func switchPort(_ measure: LinkCheckNeighborMeasure?, link: LinkCheckLink) -> LinkCheckStep {
        if let gap = neighborGap(measure, link: link) {
            return LinkCheckStep(kind: .switchPort, status: .skipped, summary: link.isWireless ? "Sans objet en Wi-Fi" : "Non mesuré",
                                 explanation: gap, seconds: measure?.listenedSeconds)
        }
        guard let measure, let neighbor = measure.neighbor else {
            let seconds = Int((measure?.listenedSeconds ?? 0).rounded())
            return LinkCheckStep(kind: .switchPort, status: .warning, summary: "Aucune annonce",
                                 explanation: "Aucune trame LLDP ni CDP en \(seconds)\(nb)s\(nb): switch non géré, LLDP désactivé sur le port, ou prise reliée à un autre appareil (téléphone IP, petit switch). Le port ne peut pas être identifié d’ici.",
                                 seconds: measure?.listenedSeconds)
        }
        var facts = [LinkCheckFact("switch", "Switch", neighbor.switchLabel)]
        if let port = neighbor.portLabel { facts.append(LinkCheckFact("port", "Port", port)) }
        if let description = neighbor.portDescription, description != neighbor.portLabel {
            facts.append(LinkCheckFact("descriptionPort", "Description du port", description))
        }
        if let model = neighbor.model { facts.append(LinkCheckFact("modele", "Modèle", model)) }
        if let management = neighbor.managementAddresses.first { facts.append(LinkCheckFact("gestion", "Gestion", management)) }
        if let link = neighbor.link { facts.append(LinkCheckFact("lienSwitch", "Lien vu par le switch", link)) }
        facts.append(LinkCheckFact("protocole", "Protocole", neighbor.protocolLabel))
        var explanation = "Annonce \(neighbor.protocolLabel) reçue" + (measure.fromPreviousCapture ? " lors de la dernière capture sur ce même lien" : "")
            + "\(nb): \(neighbor.switchLabel)" + (neighbor.portLabel.map { ", port \($0)" } ?? "") + "."
        var status = LinkCheckStatus.ok
        // Duplex annoncé par le switch (LLDP MAC/PHY ou CDP) différent de celui du Mac : désaccord.
        if let announced = neighbor.duplex?.lowercased(), let local = link.duplex {
            let switchHalf = announced.contains("half") || announced.contains("semi")
            if switchHalf != (local == .half) {
                status = .warning
                explanation += " Désaccord de duplex\(nb): le switch annonce «\(nb)\(neighbor.duplex ?? "")\(nb)», le Mac a négocié \(local.label)."
            }
        }
        if measure.fromPreviousCapture {
            explanation += " L’écoute directe n’était pas possible\(nb); lancez la Capture LLDP/CDP pour la confirmer."
        }
        let summary = neighbor.switchLabel + (neighbor.portLabel.map { " · port \($0)" } ?? "")
        return LinkCheckStep(kind: .switchPort, status: status, summary: summary, explanation: explanation, facts: facts,
                             seconds: measure.listenedSeconds)
    }

    public static func vlan(_ measure: LinkCheckNeighborMeasure?, link: LinkCheckLink, expected: Int?) -> LinkCheckStep {
        if let gap = neighborGap(measure, link: link) {
            return LinkCheckStep(kind: .vlan, status: .skipped, summary: link.isWireless ? "Sans objet en Wi-Fi" : "Non mesuré", explanation: gap)
        }
        guard let neighbor = measure?.neighbor else {
            return LinkCheckStep(kind: .vlan, status: .skipped, summary: "Non annoncé",
                                 explanation: "Sans annonce LLDP ou CDP, le VLAN du port n’est pas connu."
                                    + (expected.map { " Le VLAN attendu (\($0)) n’a pas pu être vérifié." } ?? ""))
        }
        var facts: [LinkCheckFact] = []
        if let native = neighbor.nativeVLAN { facts.append(LinkCheckFact("vlan", "VLAN natif", String(native))) }
        if let voice = neighbor.voiceVLAN { facts.append(LinkCheckFact("voix", "VLAN voix", String(voice))) }
        if !neighbor.vlanNames.isEmpty { facts.append(LinkCheckFact("noms", "Noms", neighbor.vlanNames.joined(separator: ", "))) }
        if let expected { facts.append(LinkCheckFact("attendu", "VLAN attendu", String(expected))) }
        guard let native = neighbor.nativeVLAN else {
            return LinkCheckStep(kind: .vlan, status: .skipped, summary: "Non annoncé",
                                 explanation: "Le switch ne donne pas le VLAN natif dans ses annonces (TLV 802.1 absent)."
                                    + (expected.map { " Le VLAN attendu (\($0)) n’a pas pu être vérifié." } ?? ""),
                                 facts: facts)
        }
        let voice = neighbor.voiceVLAN.map { " · voix \($0)" } ?? ""
        if let expected, expected != native {
            return LinkCheckStep(kind: .vlan, status: .failure, summary: "VLAN \(native)\(voice) (attendu \(expected))",
                                 explanation: "Le port est dans le VLAN \(native) au lieu du VLAN \(expected)\(nb): mauvais port brassé ou port mal configuré sur le switch.",
                                 facts: facts)
        }
        let explanation = "VLAN natif \(native) annoncé par le switch"
            + (neighbor.voiceVLAN.map { ", VLAN voix \($0)" } ?? "")
            + (expected != nil ? ", conforme au VLAN attendu." : ".")
        return LinkCheckStep(kind: .vlan, status: .ok, summary: "VLAN \(native)\(voice)", explanation: explanation, facts: facts)
    }

    public static func poe(_ measure: LinkCheckNeighborMeasure?, link: LinkCheckLink) -> LinkCheckStep {
        if let gap = neighborGap(measure, link: link) {
            return LinkCheckStep(kind: .poe, status: .skipped, summary: link.isWireless ? "Sans objet en Wi-Fi" : "Non mesuré", explanation: gap)
        }
        guard let neighbor = measure?.neighbor else {
            return LinkCheckStep(kind: .poe, status: .skipped, summary: "Non annoncé",
                                 explanation: "Sans annonce LLDP ou CDP, le PoE du port n’est pas connu.")
        }
        guard let power = neighbor.power else {
            if let poe = neighbor.poe {
                return LinkCheckStep(kind: .poe, status: .ok, summary: poe, explanation: "Le switch annonce\(nb): \(poe).",
                                     facts: [LinkCheckFact("poe", "PoE", poe)])
            }
            return LinkCheckStep(kind: .poe, status: .skipped, summary: "Non annoncé",
                                 explanation: "Le switch n’annonce pas de PoE sur ce port (port non PoE, ou TLV d’alimentation désactivé).")
        }
        var facts = [LinkCheckFact("poe", "PoE", power.summary)]
        if let type = power.typeLabel { facts.append(LinkCheckFact("norme", "Norme", type)) }
        if let label = power.powerLabel { facts.append(LinkCheckFact("puissance", "Puissance", label)) }
        if let cls = power.powerClass { facts.append(LinkCheckFact("classe", "Classe", String(cls))) }
        switch power.isPoEPort {
        case false?:
            return LinkCheckStep(kind: .poe, status: .ok, summary: "Port sans PoE",
                                 explanation: "Le switch annonce un port sans alimentation PoE. Un téléphone IP ou une borne ne s’allumera pas sur cette prise.",
                                 facts: facts)
        case true?:
            if power.enabled == false {
                return LinkCheckStep(kind: .poe, status: .warning, summary: power.summary,
                                     explanation: "Port PoE dont l’alimentation est désactivée sur le switch\(nb): un appareil alimenté par le câble (téléphone, borne, caméra) ne démarrera pas.",
                                     facts: facts)
            }
            let delivered = power.isPowerDelivered == true
            return LinkCheckStep(kind: .poe, status: .ok, summary: power.summary,
                                 explanation: "Port PoE disponible" + (power.typeLabel.map { ", \($0)" } ?? "")
                                    + (delivered ? ", courant fourni en ce moment." : "\(nb); ce Mac n’en consomme pas, c’est normal."),
                                 facts: facts)
        case nil:
            return LinkCheckStep(kind: .poe, status: .ok, summary: power.summary, explanation: "Le switch annonce\(nb): \(power.summary).", facts: facts)
        }
    }

    // MARK: DHCP

    public static func dhcp(_ measure: LinkCheckDHCPMeasure, link: LinkCheckLink, allowed: [IPv4Address]) -> LinkCheckStep {
        if let reason = measure.unavailableReason {
            return LinkCheckStep(kind: .dhcp, status: .skipped, summary: "Non mesuré", explanation: reason, seconds: measure.waitedSeconds)
        }
        let offers = measure.offers
        guard let first = offers.min(by: { ($0.delay ?? .infinity) < ($1.delay ?? .infinity) }) else {
            let fixed = link.hasUsableAddress
                ? " Le Mac a pourtant une adresse (\(link.address?.description ?? ""))\(nb): elle est peut-être fixe, ou le serveur ne répond qu’aux clients connus."
                : ""
            return LinkCheckStep(kind: .dhcp, status: .failure, summary: "Aucune offre",
                                 explanation: "Aucun serveur DHCP n’a répondu en \(ToolFormat.seconds(measure.waitedSeconds)). Vérifiez le VLAN du port et le relais DHCP (ip helper) du routeur." + fixed
                                    + (measure.emptyHint.map { " " + $0 } ?? ""),
                                 facts: [LinkCheckFact("serveurs", "Serveurs", "0", number: 0)], seconds: measure.waitedSeconds)
        }
        var facts = [LinkCheckFact("serveur", "Serveur", first.server?.description ?? "?"),
                     LinkCheckFact("serveurs", "Serveurs", String(offers.count), number: Double(offers.count))]
        if let delay = first.delay {
            facts.append(LinkCheckFact("temps", "Temps d’obtention", ms(delay * 1000), number: delay * 1000, higherIsBetter: false,
                                       tolerance: max(20, delay * 1000 * 0.5)))
        }
        facts.append(LinkCheckFact("offerte", "Adresse offerte", first.offeredAddress.description))
        if let subnet = first.subnet { facts.append(LinkCheckFact("reseau", "Réseau", subnet.description)) }
        if let router = first.routers.first { facts.append(LinkCheckFact("routeur", "Passerelle (3)", router.description)) }
        if !first.dnsServers.isEmpty { facts.append(LinkCheckFact("dnsOffre", "DNS (6)", first.dnsServers.map(\.description).joined(separator: ", "))) }
        if let domain = first.domainName { facts.append(LinkCheckFact("domaine", "Domaine (15)", domain)) }
        if first.leaseTime != nil { facts.append(LinkCheckFact("bail", "Bail (51)", DHCPOffer.leaseText(first.leaseTime))) }
        if let tftp = first.tftpServer { facts.append(LinkCheckFact("tftp", "TFTP (66)", tftp)) }

        let delayText = first.delay.map { " en \(ms($0 * 1000))" } ?? ""
        var summary = "\(first.server?.description ?? "?")\(delayText)"
        let policy = allowed
        let rogue = policy.isEmpty ? [] : offers.filter { offer in
            guard let server = offer.server else { return true }
            return !policy.contains(server)
        }
        if let bad = rogue.first {
            let names = rogue.compactMap { $0.server?.description }.joined(separator: ", ")
            return LinkCheckStep(kind: .dhcp, status: .failure, summary: "Serveur non autorisé\(nb): \(names)",
                                 explanation: "\(offers.count) serveur\(offers.count > 1 ? "s" : "") DHCP répondent, dont \(rogue.count) hors de la liste des serveurs autorisés (\(names)), qui distribue \(bad.subnet?.description ?? bad.offeredAddress.description)"
                                    + (bad.routers.first.map { " avec la passerelle \($0)" } ?? "") + ". Retrouvez-le avec le Test DHCP («\(nb)Voir le port de switch\(nb)») et débranchez-le.",
                                 facts: facts, seconds: measure.waitedSeconds)
        }
        if offers.count > 1 {
            let names = offers.compactMap { $0.server?.description }.joined(separator: ", ")
            return LinkCheckStep(kind: .dhcp, status: .warning, summary: "\(offers.count) serveurs\(nb): \(names)",
                                 explanation: "Plusieurs serveurs DHCP répondent sur ce segment (\(names)). Si un seul est prévu, l’autre est probablement un routeur branché à l’envers\(nb); indiquez les serveurs autorisés pour le confirmer.",
                                 facts: facts, seconds: measure.waitedSeconds)
        }
        if let delay = first.delay, delay > Threshold.dhcpSlow {
            return LinkCheckStep(kind: .dhcp, status: .warning, summary: summary,
                                 explanation: "Offre reçue après \(ms(delay * 1000))\(nb): serveur ou relais DHCP lent. Certains appareils (téléphones IP, imprimantes) abandonnent avant.",
                                 facts: facts, seconds: measure.waitedSeconds)
        }
        // Passerelle offerte différente de celle du Mac : le Mac a peut-être une adresse fixe.
        if let router = first.routers.first, let current = link.gateway, router != current {
            summary += " · passerelle \(router)"
            return LinkCheckStep(kind: .dhcp, status: .warning, summary: summary,
                                 explanation: "Le serveur offre la passerelle \(router), mais le Mac utilise \(current)\(nb): configuration fixe sur le Mac ou deux réseaux sur la même prise.",
                                 facts: facts, seconds: measure.waitedSeconds)
        }
        var explanation = "1 serveur répond (\(first.server?.description ?? "?"))\(delayText) et offre \(first.offeredAddress)"
        if let subnet = first.subnet { explanation += " dans \(subnet)" }
        explanation += first.leaseTime != nil ? ", bail de \(DHCPOffer.leaseText(first.leaseTime))." : "."
        explanation += " Aucun bail n’est pris (DHCPDISCOVER seulement)."
        return LinkCheckStep(kind: .dhcp, status: .ok, summary: summary, explanation: explanation, facts: facts, seconds: measure.waitedSeconds)
    }

    // MARK: Passerelle

    public static func gateway(_ measure: LinkCheckGatewayMeasure?, link: LinkCheckLink) -> LinkCheckStep {
        guard let measure else {
            return LinkCheckStep(kind: .passerelle, status: .skipped, summary: "Non mesuré",
                                 explanation: link.hasUsableAddress ? "Aucune passerelle par défaut n’est connue pour ce lien."
                                    : "Sans adresse IPv4, la passerelle ne peut pas être jointe.")
        }
        if let reason = measure.unavailableReason {
            return LinkCheckStep(kind: .passerelle, status: .skipped, summary: "Non mesuré", explanation: reason)
        }
        let loss = measure.lossPercent
        var facts = [LinkCheckFact("adresse", "Passerelle", measure.address.description),
                     LinkCheckFact("perte", "Perte", percent(loss), number: loss, higherIsBetter: false, tolerance: 0)]
        if let average = measure.average {
            facts.append(LinkCheckFact("latence", "Latence moyenne", ms(average), number: average, higherIsBetter: false,
                                       tolerance: max(2, average * 0.5)))
        }
        if let maximum = measure.maximum {
            facts.append(LinkCheckFact("max", "Maximum", ms(maximum), number: maximum, higherIsBetter: false, tolerance: max(5, maximum * 0.5)))
        }
        if let jitter = measure.jitter {
            facts.append(LinkCheckFact("gigue", "Gigue", ms(jitter), number: jitter, higherIsBetter: false, tolerance: max(2, jitter * 0.5)))
        }
        let sentText = "\(measure.received.count)/\(measure.sent) réponses"
        guard let average = measure.average else {
            return LinkCheckStep(kind: .passerelle, status: .failure, summary: "\(measure.address) ne répond pas",
                                 explanation: "Aucune réponse de la passerelle \(measure.address) sur \(measure.sent) pings. Si le reste fonctionne, elle bloque peut-être l’ICMP\(nb); sinon le VLAN ou l’adressage du port est en cause.",
                                 facts: facts)
        }
        let summary = "\(ms(average)) · perte \(percent(loss))"
        if loss >= Threshold.gatewayLossFailure {
            return LinkCheckStep(kind: .passerelle, status: .failure, summary: summary,
                                 explanation: "\(sentText) de \(measure.address)\(nb): perte de \(percent(loss)). Câble abîmé, port en erreur ou boucle\(nb); regardez les erreurs du port dans Switchs et ports.",
                                 facts: facts)
        }
        if loss > 0 {
            return LinkCheckStep(kind: .passerelle, status: .warning, summary: summary,
                                 explanation: "\(sentText) de \(measure.address)\(nb): quelques pertes (\(percent(loss))). À surveiller avec le ping continu.",
                                 facts: facts)
        }
        let limit = link.isWireless ? Threshold.gatewayWireless : Threshold.gatewayWired
        if average > limit {
            return LinkCheckStep(kind: .passerelle, status: .warning, summary: summary,
                                 explanation: "La passerelle répond, mais en \(ms(average)) en moyenne (au-delà de \(ms(limit)) sur un réseau local)\(nb): lien chargé ou équipement saturé.",
                                 facts: facts)
        }
        return LinkCheckStep(kind: .passerelle, status: .ok, summary: summary,
                             explanation: "\(sentText) de \(measure.address), \(ms(average)) en moyenne" + (measure.maximum.map { ", \(ms($0)) au plus" } ?? "") + ".",
                             facts: facts)
    }

    // MARK: DNS

    public static func dns(_ measure: LinkCheckDNSMeasure?, link: LinkCheckLink) -> LinkCheckStep {
        guard let measure, !measure.answers.isEmpty else {
            return LinkCheckStep(kind: .dns, status: .skipped, summary: "Non mesuré",
                                 explanation: link.hasUsableAddress ? "Aucun nom à résoudre." : "Sans adresse IPv4, le DNS ne peut pas être interrogé.")
        }
        let server = measure.server?.description ?? "résolveur du système"
        let resolved = measure.answers.filter(\.resolved)
        let times = resolved.compactMap(\.milliseconds)
        let average = times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
        var facts = [LinkCheckFact("serveur", "Serveur", server),
                     LinkCheckFact("resolus", "Noms résolus", "\(resolved.count)/\(measure.answers.count)",
                                   number: Double(resolved.count), higherIsBetter: true, tolerance: 0)]
        if let average {
            facts.append(LinkCheckFact("temps", "Temps moyen", ms(average), number: average, higherIsBetter: false,
                                       tolerance: max(15, average * 0.5)))
        }
        for answer in measure.answers {
            let value = answer.resolved
                ? (answer.addresses.first ?? "") + (answer.milliseconds.map { " · \(ms($0))" } ?? "")
                : (answer.error ?? "sans réponse")
            facts.append(LinkCheckFact("nom." + answer.name, answer.name, value))
        }
        let failed = measure.answers.filter { !$0.resolved }
        if resolved.isEmpty {
            return LinkCheckStep(kind: .dns, status: .failure, summary: "Aucun nom résolu",
                                 explanation: "Le serveur \(server) n’a résolu aucun des \(measure.answers.count) noms (\(failed.first?.error ?? "sans réponse")). Vérifiez le serveur DNS distribué par DHCP et l’accès au port 53.",
                                 facts: facts)
        }
        let summary = "\(resolved.count)/\(measure.answers.count) noms" + (average.map { " · \(ms($0))" } ?? "")
        if !failed.isEmpty {
            return LinkCheckStep(kind: .dns, status: .warning, summary: summary,
                                 explanation: "\(failed.map(\.name).joined(separator: ", ")) n’a pas été résolu par \(server)\(nb): filtrage DNS ou serveur instable.",
                                 facts: facts)
        }
        if let average, average > Threshold.dnsSlow {
            return LinkCheckStep(kind: .dns, status: .warning, summary: summary,
                                 explanation: "Les noms sont résolus, mais en \(ms(average)) en moyenne par \(server)\(nb): serveur lent ou relais vers un DNS éloigné.",
                                 facts: facts)
        }
        return LinkCheckStep(kind: .dns, status: .ok, summary: summary,
                             explanation: "\(measure.answers.map(\.name).joined(separator: ", ")) résolus par \(server)" + (average.map { " en \(ms($0)) en moyenne" } ?? "") + ".",
                             facts: facts)
    }

    // MARK: Internet

    public static func internet(_ measure: LinkCheckInternetMeasure?, link: LinkCheckLink) -> LinkCheckStep {
        guard let measure else {
            return LinkCheckStep(kind: .internet, status: .skipped, summary: "Non mesuré",
                                 explanation: "Sans adresse IPv4, Internet ne peut pas être joint.")
        }
        let host = measure.url.host ?? measure.url.absoluteString
        var facts = [LinkCheckFact("adresse", "Adresse", host)]
        if let status = measure.statusCode { facts.append(LinkCheckFact("http", "Réponse HTTP", String(status))) }
        if let time = measure.milliseconds {
            facts.append(LinkCheckFact("temps", "Temps", ms(time), number: time, higherIsBetter: false, tolerance: max(100, time * 0.5)))
        }
        if let error = measure.error {
            return LinkCheckStep(kind: .internet, status: .failure, summary: "Injoignable",
                                 explanation: "La requête vers \(host) a échoué\(nb): \(error). Le réseau local répond peut-être, mais pas la sortie Internet (pare-feu, lien WAN, proxy obligatoire).",
                                 facts: facts)
        }
        let time = measure.milliseconds.map { ms($0) } ?? "?"
        if measure.expectedTextFound == false {
            let final = measure.finalHost.map { " (redirigé vers \($0))" } ?? ""
            return LinkCheckStep(kind: .internet, status: .warning, summary: "Portail captif\(final.isEmpty ? "" : " · \(measure.finalHost ?? "")")",
                                 explanation: "\(host) a répondu, mais pas la page attendue\(final)\(nb): portail captif, proxy ou filtrage web. La navigation demandera une connexion.",
                                 facts: facts)
        }
        if let status = measure.statusCode, status >= 400 {
            return LinkCheckStep(kind: .internet, status: .warning, summary: "HTTP \(status) · \(time)",
                                 explanation: "\(host) répond avec l’erreur HTTP \(status)\(nb): filtrage web ou proxy.", facts: facts)
        }
        if let ms = measure.milliseconds, ms > Threshold.internetSlow {
            return LinkCheckStep(kind: .internet, status: .warning, summary: "Lent · \(time)",
                                 explanation: "Internet répond, mais en \(time)\(nb): lien WAN saturé ou résolution lente.", facts: facts)
        }
        return LinkCheckStep(kind: .internet, status: .ok, summary: "Accessible · \(time)",
                             explanation: "Requête HTTP vers \(host) réussie en \(time)" + (measure.statusCode.map { " (HTTP \($0))" } ?? "") + ".",
                             facts: facts)
    }
}
