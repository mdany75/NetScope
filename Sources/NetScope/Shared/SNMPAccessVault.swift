import Foundation
import NetScopeCore

// Note 59 : SNMP v3 partout. Les identifiants v3 viennent du Trousseau seulement : l'utilisateur
// « Tous les sites » (compte « identifiants », Réglages › Identifiants) et un utilisateur propre à
// chaque site qui en a un (compte « v3-site-<UUID> »). Ce coffre les lit une fois, hors du fil
// principal, et donne à chaque module (relevé des switchs, Ressources, sondes, fiche matériel,
// découverte de fin de scan, Navigateur SNMP) la cible complète d'un agent : v3 de son site d'abord,
// communauté en repli.

/// Identifiant SNMP v3 propre à un site, dans le Trousseau (service com.danymenard.netscope.snmp).
enum RegSNMPSiteVault {
    static func account(_ id: UUID) -> String { "v3-site-\(id.uuidString)" }

    static func load(_ id: UUID) -> RegSNMPCredentials? {
        guard !RegEnvironment.isSandboxed, let json = RegSNMPCredentials.keychain.string(for: account(id)) else { return nil }
        return try? JSONDecoder().decode(RegSNMPCredentials.self, from: Data(json.utf8))
    }

    /// Enregistre la partie v3 seulement (jamais de communauté par site).
    static func save(_ credentials: RegSNMPCredentials, for id: UUID) throws {
        guard !RegEnvironment.isSandboxed else { return }
        var copy = credentials
        copy.community = ""
        let data = try JSONEncoder().encode(copy)
        try RegSNMPCredentials.keychain.set(String(decoding: data, as: UTF8.self), for: account(id))
    }

    static func erase(_ id: UUID) throws {
        guard !RegEnvironment.isSandboxed else { return }
        try RegSNMPCredentials.keychain.delete(account(id))
    }
}

extension RegSNMPCredentials {
    /// Champs v3 des Réglages repris d'un identifiant du moteur (démonstration, captures).
    init(v3 credentials: SNMPv3Credentials) {
        self.init()
        v3User = credentials.user
        v3Level = Level(rawValue: credentials.level.rawValue) ?? .authPriv
        v3AuthProtocol = credentials.auth.rawValue
        v3AuthPassword = credentials.authPassword
        v3PrivProtocol = credentials.priv.rawValue
        v3PrivPassword = credentials.privPassword
        v3Context = credentials.context
    }
}

/// Identifiants SNMP v3 en mémoire (lus au Trousseau) et choix de la cible de chaque agent.
@MainActor
final class SNMPAccessVault: ObservableObject {
    static let shared = SNMPAccessVault()

    /// Utilisateur « Tous les sites » (nil : aucun).
    @Published private(set) var global: SNMPv3Credentials?
    /// Utilisateurs propres aux sites.
    @Published private(set) var perSite: [UUID: SNMPv3Credentials] = [:]

    private var loadTask: Task<Void, Never>?
    /// Numéro de la lecture en cours : le résultat d'une lecture remplacée (reload) est ignoré.
    private var generation = 0
    /// Modifiés par `update(...)` pendant la lecture en cours : leur valeur l'emporte sur celle lue.
    private var updatedGlobal = false
    private var updatedSites: Set<UUID> = []
    private let isDemo: Bool

    private init() {
        isDemo = Launcher.isDemo
        if isDemo {
            // Démonstration : identifiants fictifs (aucun envoi, rien n'est lu au Trousseau).
            global = SNMPAccessDemo.global
            perSite = SNMPAccessDemo.perSite
        }
    }

    /// Lit les identifiants au Trousseau, une fois, hors du fil principal (une demande d'accès de
    /// macOS ne gèle donc pas l'app).
    func load() async {
        guard !RegEnvironment.isSandboxed else { return }
        if loadTask == nil {
            let ids = SiteModel.shared.sites.map(\.id)
            let current = generation
            updatedGlobal = false
            updatedSites = []
            loadTask = Task { [weak self] in
                let (global, sites) = await Task.detached(priority: .userInitiated) { () -> (SNMPv3Credentials?, [UUID: SNMPv3Credentials]) in
                    let saved = RegSNMPCredentials.load()
                    let global = saved.flatMap { $0.v3User.isEmpty ? nil : $0.v3Credentials }
                    var sites: [UUID: SNMPv3Credentials] = [:]
                    for id in ids {
                        if let site = RegSNMPSiteVault.load(id), !site.v3User.isEmpty { sites[id] = site.v3Credentials }
                    }
                    return (global, sites)
                }.value
                self?.apply(global: global, sites: sites, generation: current)
            }
        }
        await loadTask?.value
    }

    /// Identifiants modifiés dans les Réglages : relecture, et oubli des moteurs et versions retenus.
    func reload() {
        loadTask?.cancel()
        loadTask = nil
        generation += 1
        SNMPv3Session.reset()
        SNMPVersionMemo.shared.reset()
        Task { await load() }
    }

    /// Résultat d'une lecture : ignoré s'il vient d'une lecture remplacée ; ce qui a été enregistré
    /// pendant la lecture (update) n'est pas écrasé par des valeurs plus anciennes.
    private func apply(global loaded: SNMPv3Credentials?, sites loadedSites: [UUID: SNMPv3Credentials], generation current: Int) {
        guard current == generation else { return }
        if !updatedGlobal { global = loaded }
        var merged = loadedSites
        for id in updatedSites { merged[id] = perSite[id] }
        perSite = merged
    }

    /// Identifiant v3 d'un agent : celui de son site, sinon celui de tous les sites.
    func v3(for host: IPv4Address) -> SNMPv3Credentials? {
        lookup(host)
    }

    func v3(for host: String) -> SNMPv3Credentials? {
        IPv4Address(host).flatMap { v3(for: $0) }
    }

    /// Site dont vient l'identifiant v3 d'un agent (nil : « Tous les sites » ou aucun).
    func site(for host: IPv4Address) -> Site? {
        let sites = SiteModel.shared
        guard let id = SNMPv3SiteResolver.site(for: host, sites: sites.sites, activeID: sites.activeSite?.id,
                                               configured: Set(perSite.keys)) else { return nil }
        return sites.site(id)
    }

    /// Table figée, utilisable hors du fil principal (sondes, découverte).
    var lookup: SNMPv3Lookup {
        let sites = SiteModel.shared
        return SNMPv3SiteResolver.lookup(sites: sites.sites, activeID: sites.activeSite?.id, perSite: perSite, fallback: global)
    }

    /// Cible complète d'un agent : v3 de son site d'abord, communauté en repli.
    func target(host: IPv4Address, community: String, timeout: TimeInterval = 2, retries: Int = 1) -> SNMPTarget {
        SNMPTarget(host: host, community: community, v3: v3(for: host), timeout: timeout, retries: retries)
    }

    /// Vrai si au moins un utilisateur v3 est enregistré (tous les sites ou un site).
    var hasAnyV3: Bool { global != nil || !perSite.isEmpty }

    /// Vrai si l'agent a au moins un identifiant (communauté ou v3).
    func hasAccess(_ host: String, community: String) -> Bool {
        !community.isEmpty || v3(for: host) != nil
    }

    /// Mise à jour après un enregistrement dans les Réglages (sans attendre la relecture).
    func update(global credentials: SNMPv3Credentials?) {
        global = credentials
        updatedGlobal = true
        SNMPv3Session.reset()
        SNMPVersionMemo.shared.reset()
    }

    func update(site id: UUID, credentials: SNMPv3Credentials?) {
        perSite[id] = credentials
        updatedSites.insert(id)
        SNMPv3Session.reset()
        SNMPVersionMemo.shared.reset()
    }
}

extension SwitchStore {
    /// Cible SNMP d'un switch : communauté retenue (découverte ou saisie) et utilisateur v3 du site.
    func snmpTarget(for host: String, timeout: TimeInterval = 2, retries: Int = 1) -> SNMPTarget? {
        guard let ip = IPv4Address(host) else { return nil }
        let target = SNMPAccessVault.shared.target(host: ip, community: community(for: host), timeout: timeout, retries: retries)
        return target.hasCredentials ? target : nil
    }

    /// Vrai si ce switch peut être interrogé (communauté ou utilisateur v3).
    func hasSNMPAccess(_ host: String) -> Bool {
        SNMPAccessVault.shared.hasAccess(host, community: community(for: host))
    }
}
