import AppKit
import NetScopeCore
import SwiftUI

// Note 69 : scan de ports UDP ciblé. État par hôte, partagé par la fiche Appareil (onglet Ports
// et services), la feuille du Scanner (« Scanner les ports › UDP ciblé… ») et l'outil Scan de
// ports de la Boîte à outils (protocole « UDP ciblé »). Lancé seulement sur clic ; en
// démonstration, rien ne part sur le réseau (DevTools/UDPScanDemo.swift).

/// Communauté SNMP v2c envoyée avec la sonde SNMP.
enum UDPCommunityChoice: String, CaseIterable, Identifiable {
    /// Celle qui a répondu pour cet hôte (découverte des switchs), sinon celle des Identifiants ;
    /// jamais « public » par défaut.
    case site
    /// « public », seulement quand l'utilisateur la choisit.
    case publique
    /// Aucune : découverte SNMP v3 seulement (aucun secret envoyé).
    case aucune

    var id: String { rawValue }

    var label: String {
        switch self {
        case .site: return "Communauté du site (Identifiants)"
        case .publique: return "«\u{00A0}public\u{00A0}» (communauté par défaut)"
        case .aucune: return "Aucune (découverte SNMP v3 seulement)"
        }
    }
}

/// État du scan UDP d'un hôte.
struct UDPHostState {
    var summary: UDPScanSummary?
    var isRunning = false
    var done = 0
    var total = 0
    /// Résultats arrivés pendant le scan.
    var partial: [UDPProbeResult] = []
    var error: String?
    /// Communauté utilisée, décrite sans la dévoiler (« communauté du site », « public »…).
    var communityNote: String?

    var rows: [UDPProbeResult] { summary?.results ?? partial }
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

/// Feuille du Scanner.
struct UDPScanTarget: Identifiable {
    let host: String
    let name: String
    var id: String { host }

    init(host: String, name: String) {
        self.host = host
        self.name = name
    }

    init(device: Device) {
        self.init(host: device.ip.description, name: device.displayName)
    }
}

@MainActor
final class UDPScanModel: ObservableObject {
    static let shared = UDPScanModel()

    private static let servicesKey = "udp.sondes"
    private static let communityKey = "udp.communaute"
    private static let ntpKey = "udp.testsNTP"

    @Published private(set) var hosts: [String: UDPHostState] = [:]
    @Published var target: UDPScanTarget?
    /// Sondes cochées (toutes par défaut).
    @Published var services: Set<UDPService> {
        didSet { save(services.map(\.rawValue).sorted(), Self.servicesKey) }
    }
    @Published var community: UDPCommunityChoice {
        didSet { save(community.rawValue, Self.communityKey) }
    }
    /// Requêtes NTP de contrôle (mode 6) et privées (mode 7, monlist).
    @Published var ntpChecks: Bool {
        didSet { save(ntpChecks, Self.ntpKey) }
    }

    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: Int] = [:]

    private init() {
        let defaults = UserDefaults.standard
        if RegEnvironment.isSandboxed {
            services = Set(UDPService.allCases)
            community = .site
            ntpChecks = true
            if Launcher.isDemo { hosts = UDPScanDemo.initialStates() }
        } else {
            let saved = (defaults.array(forKey: Self.servicesKey) as? [String])?.compactMap(UDPService.init(rawValue:))
            services = Set(saved?.isEmpty == false ? saved ?? [] : UDPService.allCases)
            community = defaults.string(forKey: Self.communityKey).flatMap(UDPCommunityChoice.init(rawValue:)) ?? .site
            ntpChecks = defaults.object(forKey: Self.ntpKey) as? Bool ?? true
        }
    }

    private func save(_ value: Any, _ key: String) {
        guard !RegEnvironment.isSandboxed else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    func state(for host: String) -> UDPHostState { hosts[host] ?? UDPHostState() }

    /// Sondes cochées, dans l'ordre des ports.
    var orderedServices: [UDPService] { UDPService.allCases.filter(services.contains) }

    func toggle(_ service: UDPService) {
        if services.contains(service) {
            guard services.count > 1 else { return }
            services.remove(service)
        } else {
            services.insert(service)
        }
    }

    /// « 9 sondes », « 3 sondes ».
    var servicesLabel: String {
        services.count == UDPService.allCases.count ? "toutes les sondes" : "\(services.count) sonde\(services.count > 1 ? "s" : "")"
    }

    /// Menu du Scanner : feuille de l'appareil, scan lancé tout de suite (le clic du menu).
    func ask(_ device: Device) {
        target = UDPScanTarget(device: device)
        scan(host: device.ip.description)
    }

    /// Communauté v2c à envoyer à `host`, et sa description (sans la valeur). `isSiteMember` :
    /// l'adresse résolue est privée ou dans les plages du site ; sinon seule la communauté
    /// propre à l'hôte peut partir (la communauté générale du site reste chez nous).
    func communityToSend(for host: String, isSiteMember: Bool = true) -> (value: String?, note: String) {
        switch community {
        case .aucune:
            return (nil, "SNMP v3 seulement")
        case .publique:
            return ("public", "communauté «\u{00A0}public\u{00A0}»")
        case .site:
            let perHost = RegSNMPDiscoveryVault.hostCommunities()[host]
            // « public » n'est jamais envoyée sans le choix explicite de l'utilisateur.
            if let value = perHost, !value.isEmpty, value != "public" { return (value, "communauté du site") }
            guard let saved = RegSNMPCredentials.load()?.community, !saved.isEmpty, saved != "public" else {
                return (nil, "aucune communauté enregistrée\u{00A0}: SNMP v3 seulement")
            }
            guard isSiteMember else { return (nil, UDPCommunityPolicy.withheldNote) }
            return (saved, "communauté du site")
        }
    }

    /// Commande équivalente pour l'historique de la Boîte à outils.
    func command(host: String) -> String {
        "scan -sU -p " + orderedServices.map { String($0.port) }.joined(separator: ",") + " \(host)"
    }

    /// Lance le scan de `host` (IP ou nom).
    func scan(host rawHost: String, store providedStore: ToolStore? = nil) {
        let store = providedStore ?? .shared
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            update(rawHost) { $0.error = "Saisir une adresse IP ou un nom d’hôte." }
            return
        }
        guard host.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            update(host) { $0.error = "«\u{00A0}\(host)\u{00A0}» n’est pas une adresse IPv4 ou un nom d’hôte valide." }
            return
        }
        // Note 82 : une adresse des plages exclues du site actif n'est jamais sondée.
        if let address = IPv4Address(host), let reason = SiteModel.shared.exclusionReason(address) {
            update(host) { $0.error = reason + "\u{00A0}: retirez-la des plages exclues (Réglages › Sites et plages) pour la sonder." }
            return
        }
        let services = orderedServices
        // Note provisoire : la communauté réellement envoyée est choisie après la résolution du nom.
        let literal = IPv4Address(host)
        let (_, note) = Launcher.isDemo ? demoCommunity : communityToSend(for: host, isSiteMember: literal.map(isSiteMember) ?? true)
        let ntpChecks = self.ntpChecks
        tasks[host]?.cancel()
        let run = (generations[host] ?? 0) + 1
        generations[host] = run
        update(host) {
            $0 = UDPHostState(summary: nil, isRunning: true, done: 0, total: services.count, partial: [], error: nil, communityNote: note)
        }
        store.record(command: command(host: host))
        let choice = self.community
        tasks[host] = Task { [weak self] in
            let summary: UDPScanSummary
            if Launcher.isDemo {
                // Démonstration : aucune sonde ne part, résultats fixes après un court délai.
                try? await Task.sleep(nanoseconds: 900_000_000)
                summary = UDPScanDemo.summary(for: host, services: services, community: choice, ntpChecks: ntpChecks)
            } else {
                let resolved = await Task.detached { try? PingResolver.resolve(host) }.value
                guard let address = resolved else {
                    self?.finish(host, run: run, error: "Nom d’hôte introuvable\u{00A0}: «\u{00A0}\(host)\u{00A0}».")
                    return
                }
                guard let model = self, model.generations[host] == run else { return }
                // Note 82 : un nom qui se résout en une adresse exclue n'est pas sondé non plus.
                if let reason = SiteModel.shared.exclusionReason(address) {
                    model.finish(host, run: run, error: reason + "\u{00A0}: retirez-la des plages exclues (Réglages › Sites et plages) pour la sonder.")
                    return
                }
                // La communauté générale du site ne part que vers une adresse privée ou des plages du site.
                let (community, note) = model.communityToSend(for: host, isSiteMember: model.isSiteMember(address))
                model.update(host) { $0.communityNote = note }
                let options = UDPProbeOptions(timeout: 1.5, attempts: 2, snmpCommunity: community, ntpControlChecks: ntpChecks)
                summary = await UDPPortScanner.scan(host: address, services: services, options: options) { done, total, latest in
                    Task { @MainActor in self?.progress(host, run: run, done: done, total: total, latest: latest) }
                }
            }
            self?.finish(host, run: run, summary: summary, store: store)
        }
    }

    /// Adresse privée ou dans les plages du site actif : la communauté générale peut lui être envoyée.
    private func isSiteMember(_ address: IPv4Address) -> Bool {
        UDPCommunityPolicy.maySendSiteCommunity(to: address, siteRanges: SiteModel.shared.activeSite?.ranges.map(\.text) ?? [])
    }

    /// Démonstration : la communauté choisie, sans Trousseau.
    private var demoCommunity: (String?, String) {
        switch community {
        case .aucune: return (nil, "SNMP v3 seulement")
        case .publique: return ("public", "communauté «\u{00A0}public\u{00A0}»")
        case .site: return ("lecture-demo", "communauté du site")
        }
    }

    func cancel(host: String) {
        tasks[host]?.cancel()
        tasks[host] = nil
        generations[host, default: 0] += 1
        update(host) { state in
            state.isRunning = false
            if state.summary == nil, !state.partial.isEmpty {
                state.summary = UDPScanSummary(host: host, results: state.partial, duration: 0, wasCancelled: true)
            }
        }
    }

    func copyCSV(host: String) {
        guard let summary = state(for: host).summary else { return }
        ToolActions.copy(summary.csv)
    }

    private func progress(_ host: String, run: Int, done: Int, total: Int, latest: UDPProbeResult) {
        guard generations[host] == run else { return }
        update(host) { state in
            state.done = max(state.done, done)
            state.total = total
            state.partial.removeAll { $0.port == latest.port }
            state.partial.append(latest)
            state.partial.sort { $0.port < $1.port }
        }
    }

    private func finish(_ host: String, run: Int, summary: UDPScanSummary? = nil, error: String? = nil, store: ToolStore? = nil) {
        guard generations[host] == run else { return }
        tasks[host] = nil
        update(host) { state in
            state.isRunning = false
            state.error = error
            if let summary {
                state.summary = summary
                state.done = summary.results.count
            }
        }
        guard let summary else { return }
        let findings = summary.findings
        let text = findings.isEmpty ? summary.summary
            : summary.summary + " · " + findings.prefix(2).map(\.title).joined(separator: ", ") + (findings.count > 2 ? "…" : "")
        let status: ToolRecent.Status = summary.wasCancelled ? .info : findings.contains { $0.severity == .eleve } ? .warning : .ok
        (store ?? .shared).record(ToolRecent(tool: .ports, target: host, summary: (summary.wasCancelled ? "Interrompu · " : "") + text,
                                status: status, title: "Scan UDP ciblé"))
    }

    private func update(_ host: String, _ change: (inout UDPHostState) -> Void) {
        var state = hosts[host] ?? UDPHostState()
        change(&state)
        hosts[host] = state
    }
}
