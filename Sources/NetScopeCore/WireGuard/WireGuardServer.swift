import Foundation

// Note 100 (1.3.0) : serveur WireGuard (wg-easy, en conteneur) lu par SSH, avec le compte du serveur
// RustDesk (même connexion, même sudo). Lecture seule : wg show all dump dans le conteneur, base
// wg-easy.db copiée puis lue (sqlite3 seulement s'il existe, jamais ouverte en écriture), état et
// version du conteneur, journaux ; wg-easy 14 reconnue (wg0.json, clés retirées avant l'envoi).

// MARK: - Script de lecture

public enum WireGuardServerScript {
    public static let defaultContainer = "wg-easy"

    /// Variables d'environnement du conteneur montrées (jamais PASSWORD, PASSWORD_HASH ni autre secret).
    public static let shownEnvironment = ["INSECURE", "PORT", "WG_PORT", "WG_HOST", "HOST", "DISABLE_IPV6", "INIT_ENABLED"]

    /// Script de lecture. Mot de passe sudo éventuel en première ligne de l'entrée standard
    /// (`RustDeskServerDetailScript.remoteCommand`) ; le nom du conteneur est validé avant.
    public static func read(container: String) throws -> String {
        let name = try RustDeskActionValidation.containerName(container)
        return prelude + "\nC='\(name)'\n" + body
    }

    static let prelude = #"""
    # NetScope : lecture seule du serveur WireGuard (wg-easy) ; aucune commande ne modifie le serveur.
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    section() { printf '\n@@NETSCOPE %s@@\n' "$1"; }
    asroot() {
      if [ "$(id -u)" = 0 ]; then "$@"
      elif [ -n "$NETSCOPE_MDP" ]; then printf '%s\n' "$NETSCOPE_MDP" | sudo -k -S -p '' -- "$@"
      else sudo -n -- "$@"
      fi
    }
    DKDIRECT=0
    if [ "$(id -u)" = 0 ] || id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx docker; then DKDIRECT=1; fi
    dk() { if [ "$DKDIRECT" = 1 ]; then timeout 20 docker "$@" </dev/null; else asroot timeout 20 docker "$@"; fi; }
    section ACCES
    if [ "$(id -u)" = 0 ]; then echo 'SUDO root'
    elif [ "$DKDIRECT" = 1 ]; then echo 'SUDO docker'
    elif ! command -v sudo >/dev/null 2>&1; then echo 'SUDO absent'
    elif asroot true >/dev/null 2>&1; then echo 'SUDO ok'
    else echo 'SUDO refuse'; NETSCOPE_MDP=
    fi
    """#

    static let body = #"""
    section CONTENEUR
    if ! command -v docker >/dev/null 2>&1; then echo 'docker=absent'; section FIN; exit 0; fi
    if [ -z "$(dk inspect --format '{{.Name}}' "$C" 2>/dev/null)" ]; then
      A=$(dk ps --all --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -i 'wg-easy' | head -n 1 | cut -d'|' -f1)
      [ -n "$A" ] && C=$A
    fi
    if [ -z "$(dk inspect --format '{{.Name}}' "$C" 2>/dev/null)" ]; then echo 'conteneur=absent'; section FIN; exit 0; fi
    dk inspect --format 'nom={{.Name}}
    etat={{.State.Status}}
    demarre={{.State.StartedAt}}
    redemarrages={{.RestartCount}}
    image={{.Config.Image}}
    imageid={{.Image}}
    version={{index .Config.Labels "org.opencontainers.image.version"}}' "$C" 2>/dev/null
    dk inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$C" 2>/dev/null \
      | grep -E '^(INSECURE|PORT|WG_PORT|WG_HOST|HOST|DISABLE_IPV6|INIT_ENABLED)=' | sed 's/^/env /'
    section EDITION
    if dk exec "$C" test -f /etc/wireguard/wg-easy.db 2>/dev/null; then echo 15; fi
    if dk exec "$C" test -f /etc/wireguard/wg0.json 2>/dev/null; then echo 14; fi
    section DUMP
    # Clé privée de l'interface et clés partagées des pairs remplacées avant l'envoi.
    dk exec "$C" wg show all dump 2>/dev/null | awk 'BEGIN { FS = OFS = "\t" } NF == 5 { $2 = "(masquee)" } NF == 9 { $3 = "(masquee)" } { print }'
    section CLIENTS14
    if dk exec "$C" test -f /etc/wireguard/wg0.json 2>/dev/null; then
      dk exec "$C" cat /etc/wireguard/wg0.json 2>/dev/null \
        | sed -E 's/("(privateKey|preSharedKey)"[[:space:]]*:[[:space:]]*)"[^"]*"/\1""/g' | head -c 400000
    fi
    section BASE
    if ! command -v sqlite3 >/dev/null 2>&1; then echo 'SQLITE absent'
    elif dk exec "$C" test -f /etc/wireguard/wg-easy.db 2>/dev/null; then
      # Copie de la base (clés des clients) : effacée à la sortie, même si ssh est coupé ou sqlite3 bloqué.
      T=$(mktemp -d /tmp/netscope-wg.XXXXXX 2>/dev/null) || T=
      case "$T" in /tmp/netscope-wg.?*) ;; *) T= ;; esac
      if [ -n "$T" ] && [ -d "$T" ]; then
        trap 'if [ -n "$T" ]; then asroot rm -rf "$T" 2>/dev/null; rm -rf "$T" 2>/dev/null; fi' EXIT
        trap 'exit 1' HUP INT TERM PIPE
        chmod 700 "$T"
        for f in wg-easy.db wg-easy.db-wal wg-easy.db-shm; do dk cp "$C:/etc/wireguard/$f" "$T/$f" >/dev/null 2>&1; done
        [ "$DKDIRECT" = 1 ] || asroot chown -R "$(id -u)" "$T" 2>/dev/null
        timeout 15 sqlite3 -readonly -separator '|' "$T/wg-easy.db" "SELECT id, replace(replace(name,'|','/'),char(10),' '), IFNULL(ipv4_address,''), IFNULL(ipv6_address,''), IFNULL(public_key,''), enabled, IFNULL(expires_at,'') FROM clients_table ORDER BY id;" 2>/dev/null | sed 's/^/client|/'
        if [ "$DKDIRECT" = 1 ]; then rm -rf "$T"; else asroot rm -rf "$T"; fi
        rm -rf "$T" 2>/dev/null; T=
      else echo 'BASE erreur'
      fi
    fi
    section JOURNAUX
    dk logs --tail 60 "$C" 2>&1 | tail -n 60 | cut -c1-300
    section FIN
    """#
}

// MARK: - État lu

/// Conteneur wg-easy.
public struct WireGuardContainer: Equatable, Codable, Sendable {
    public var name: String
    public var state: String
    public var startedAt: Date?
    public var restarts: Int
    public var image: String
    public var imageID: String
    public var version: String

    public init(name: String, state: String, startedAt: Date? = nil, restarts: Int = 0, image: String = "", imageID: String = "", version: String = "") {
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.restarts = restarts
        self.image = image
        self.imageID = imageID
        self.version = version
    }

    public var isRunning: Bool { state == "running" }
}

/// Édition de wg-easy reconnue.
public enum WireGuardEdition: String, Codable, Sendable {
    case v15, v14, unknown
}

/// Client connu par la base (15) ou par wg0.json (14) : jamais de clé privée.
public struct WireGuardKnownClient: Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var ipv4: String
    public var ipv6: String
    public var publicKey: String
    public var enabled: Bool
    public var expiresAt: Date?

    public init(id: String, name: String, ipv4: String = "", ipv6: String = "", publicKey: String, enabled: Bool = true, expiresAt: Date? = nil) {
        self.id = id
        self.name = name
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.publicKey = publicKey
        self.enabled = enabled
        self.expiresAt = expiresAt
    }
}

public struct WireGuardServerStatus: Equatable, Codable, Sendable {
    public var readAt: Date
    /// « root », « docker », « ok », « refuse », « absent ».
    public var access: String
    public var dockerMissing = false
    public var container: WireGuardContainer?
    public var environment: [String: String] = [:]
    public var edition: WireGuardEdition = .unknown
    public var dump = WireGuardDump()
    /// Clients lus dans la base (15) ; nil : base non lue.
    public var databaseClients: [WireGuardKnownClient]?
    public var sqliteMissing = false
    /// Clients de wg0.json (14).
    public var legacyClients: [WireGuardKnownClient] = []
    public var logs: [String] = []
    public var complete = false

    public init(readAt: Date, access: String = "", container: WireGuardContainer? = nil) {
        self.readAt = readAt
        self.access = access
        self.container = container
    }

    /// Clé publique et port de wg0.
    public var serverKey: String? { dump.interfaces.first?.publicKey }
    public var listenPort: Int? { dump.interfaces.first?.listenPort }

    /// Interface en HTTP simple (INSECURE=true) : mot de passe en clair à chaque appel.
    public var insecure: Bool? {
        environment["INSECURE"].map { $0.lowercased() == "true" || $0 == "1" }
    }
}

public enum WireGuardServerOutput {
    public static func parse(_ text: String, readAt: Date) -> WireGuardServerStatus {
        let parts = RustDeskServerOutput.sections(text)
        var status = WireGuardServerStatus(readAt: readAt)
        status.complete = parts["FIN"] != nil
        if let line = parts["ACCES"]?.lines.first, line.hasPrefix("SUDO ") { status.access = String(line.dropFirst(5)) }
        var values: [String: String] = [:]
        for line in parts["CONTENEUR"]?.lines ?? [] {
            if line.hasPrefix("env "), let equal = line.firstIndex(of: "=") {
                let key = String(line[line.index(line.startIndex, offsetBy: 4)..<equal])
                if WireGuardServerScript.shownEnvironment.contains(key) {
                    status.environment[key] = String(line[line.index(after: equal)...])
                }
            } else if let equal = line.firstIndex(of: "=") {
                values[String(line[..<equal])] = String(line[line.index(after: equal)...])
            }
        }
        if values["docker"] == "absent" { status.dockerMissing = true }
        if let name = values["nom"], values["conteneur"] != "absent" {
            status.container = WireGuardContainer(name: name.hasPrefix("/") ? String(name.dropFirst()) : name,
                                                  state: values["etat"] ?? "", startedAt: values["demarre"].flatMap(WGEasyAPI.date),
                                                  restarts: Int(values["redemarrages"] ?? "") ?? 0, image: values["image"] ?? "",
                                                  imageID: values["imageid"] ?? "",
                                                  version: values["version"].map { $0 == "<no value>" ? "" : $0 } ?? "")
        }
        let editions = Set(parts["EDITION"]?.lines ?? [])
        status.edition = editions.contains("15") ? .v15 : editions.contains("14") ? .v14 : .unknown
        status.dump = WireGuardDump.parse((parts["DUMP"]?.lines ?? []).joined(separator: "\n"))
        let legacy = (parts["CLIENTS14"]?.lines ?? []).joined(separator: "\n")
        if !legacy.isEmpty { status.legacyClients = legacyClients(Data(legacy.utf8)) }
        if let base = parts["BASE"] {
            if base.lines.contains("SQLITE absent") {
                status.sqliteMissing = true
            } else if base.lines.contains(where: { $0.hasPrefix("client|") }) {
                status.databaseClients = base.lines.compactMap(databaseClient)
            }
        }
        status.logs = (parts["JOURNAUX"]?.lines ?? []).map { RemoteShell.sanitizedTitle($0, limit: 300) }
        return status
    }

    /// « client|id|nom|ipv4|ipv6|clé|activé|expiration ».
    static func databaseClient(_ line: String) -> WireGuardKnownClient? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 8, f[0] == "client", WireGuardDump.isKey(f[5]) else { return nil }
        return WireGuardKnownClient(id: f[1], name: f[2], ipv4: f[3], ipv6: f[4], publicKey: f[5], enabled: f[6] == "1" || f[6] == "true",
                                    expiresAt: f[7].isEmpty ? nil : WGEasyAPI.date(f[7]))
    }

    /// wg0.json de wg-easy 14 (clés privées déjà vidées par le script ; ignorées ici de toute façon).
    public static func legacyClients(_ data: Data) -> [WireGuardKnownClient] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clients = object["clients"] as? [String: Any] else { return [] }
        return clients.compactMap { id, value -> WireGuardKnownClient? in
            guard let client = value as? [String: Any], let key = client["publicKey"] as? String, WireGuardDump.isKey(key) else { return nil }
            return WireGuardKnownClient(id: id, name: (client["name"] as? String) ?? id, ipv4: (client["address"] as? String) ?? "",
                                        publicKey: key, enabled: (client["enabled"] as? Bool) ?? true,
                                        expiresAt: (client["expiredAt"] as? String).flatMap(WGEasyAPI.date))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Lignes du tableau

/// Une ligne par client : nom et réglages (API, base ou wg0.json), activité (wg show).
public struct WireGuardClientRow: Equatable, Identifiable, Sendable {
    public var id: String { publicKey.isEmpty ? "api-\(apiID ?? 0)" : publicKey }
    public var publicKey: String
    public var name: String
    public var ipv4: String
    public var ipv6: String
    public var enabled: Bool
    public var expiresAt: Date?
    public var endpoint: String?
    public var endpointAddress: String?
    public var latestHandshake: Date?
    public var receivedBytes: Int64
    public var sentBytes: Int64
    /// Identifiant de l'API (gestion possible).
    public var apiID: Int?
    public var dns: [String]?

    public func isConnected(now: Date) -> Bool {
        guard let latestHandshake else { return false }
        return now.timeIntervalSince(latestHandshake) < WireGuardDump.connectedWindow
    }

    /// Fusion par clé publique. Ordre de préférence des fiches : API, base, wg0.json ; un pair
    /// sans fiche s'affiche sous un nom tiré de sa clé (« Pair abcd1234… »).
    public static func rows(status: WireGuardServerStatus?, api: [WGEasyClient]?) -> [WireGuardClientRow] {
        var peers: [String: WireGuardPeer] = [:]
        for peer in status?.dump.peers ?? [] { peers[peer.publicKey] = peer }
        var rows: [WireGuardClientRow] = []
        var seen = Set<String>()
        func activity(_ row: inout WireGuardClientRow) {
            guard let peer = peers[row.publicKey] else { return }
            row.endpoint = peer.endpoint
            row.endpointAddress = peer.endpointAddress
            row.latestHandshake = peer.latestHandshake
            row.receivedBytes = peer.receivedBytes
            row.sentBytes = peer.sentBytes
        }
        if let api {
            for client in api {
                var row = WireGuardClientRow(publicKey: client.publicKey ?? "", name: client.name, ipv4: client.ipv4Address ?? "",
                                             ipv6: client.ipv6Address ?? "", enabled: client.enabled, expiresAt: client.expiresAt,
                                             endpoint: client.endpoint, endpointAddress: nil, latestHandshake: client.latestHandshakeAt,
                                             receivedBytes: client.transferRx ?? 0, sentBytes: client.transferTx ?? 0, apiID: client.id, dns: client.dns)
                activity(&row)
                if !row.publicKey.isEmpty { seen.insert(row.publicKey) }
                rows.append(row)
            }
        }
        let known = status?.databaseClients ?? status?.legacyClients ?? []
        for client in known where !seen.contains(client.publicKey) {
            var row = WireGuardClientRow(publicKey: client.publicKey, name: client.name, ipv4: client.ipv4, ipv6: client.ipv6,
                                         enabled: client.enabled, expiresAt: client.expiresAt, endpoint: nil, endpointAddress: nil,
                                         latestHandshake: nil, receivedBytes: 0, sentBytes: 0, apiID: nil, dns: nil)
            activity(&row)
            seen.insert(client.publicKey)
            rows.append(row)
        }
        for peer in status?.dump.peers ?? [] where !seen.contains(peer.publicKey) {
            rows.append(WireGuardClientRow(publicKey: peer.publicKey, name: "Pair " + String(peer.publicKey.prefix(8)) + "…",
                                           ipv4: peer.allowedIPs.first ?? "", ipv6: "", enabled: true, expiresAt: nil,
                                           endpoint: peer.endpoint, endpointAddress: peer.endpointAddress, latestHandshake: peer.latestHandshake,
                                           receivedBytes: peer.receivedBytes, sentBytes: peer.sentBytes, apiID: nil, dns: nil))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Échantillons (graphe)

/// Mesure à chaque lecture : clients connectés et octets cumulés (tous les pairs).
public struct WireGuardSample: Equatable, Codable, Sendable {
    public var date: Date
    public var connected: Int
    public var receivedBytes: Int64
    public var sentBytes: Int64

    public init(date: Date, connected: Int, receivedBytes: Int64, sentBytes: Int64) {
        self.date = date
        self.connected = connected
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public enum WireGuardSamples {
    public static let keep: TimeInterval = 3 * 86_400

    public static func sample(from status: WireGuardServerStatus) -> WireGuardSample? {
        guard status.container?.isRunning == true, !status.dump.interfaces.isEmpty else { return nil }
        let peers = status.dump.peers
        return WireGuardSample(date: status.readAt,
                               connected: peers.filter { $0.latestHandshake.map { status.readAt.timeIntervalSince($0) < WireGuardDump.connectedWindow } ?? false }.count,
                               receivedBytes: peers.reduce(0) { $0 + $1.receivedBytes }, sentBytes: peers.reduce(0) { $0 + $1.sentBytes })
    }

    public static func adding(_ sample: WireGuardSample, to samples: [WireGuardSample], now: Date) -> [WireGuardSample] {
        (samples + [sample]).filter { now.timeIntervalSince($0.date) <= keep }.sorted { $0.date < $1.date }
    }

    /// Débit (octets/s) entre deux mesures : ↓ reçu par le serveur, ↑ envoyé ; nil si les
    /// compteurs ont été remis à zéro (redémarrage) ou si l'écart est trop court.
    public static func rate(from a: WireGuardSample, to b: WireGuardSample) -> (down: Double, up: Double)? {
        let seconds = b.date.timeIntervalSince(a.date)
        guard seconds >= 1, b.receivedBytes >= a.receivedBytes, b.sentBytes >= a.sentBytes else { return nil }
        return (Double(b.receivedBytes - a.receivedBytes) / seconds, Double(b.sentBytes - a.sentBytes) / seconds)
    }

    /// « 1,2 Mbit/s » d'un débit en octets par seconde.
    public static func bitrate(_ bytesPerSecond: Double) -> String {
        RustDeskServerFormat.kbps(Int((bytesPerSecond * 8 / 1_000).rounded()))
    }
}

// MARK: - Règles d'alerte

/// Réglages de la surveillance du serveur WireGuard.
public struct WireGuardWatchSettings: Equatable, Codable, Sendable {
    /// Clés publiques des clients importants.
    public var importantKeys: [String] = []
    /// Client important déconnecté depuis plus de ces heures.
    public var disconnectedHours: Double = 4
    /// Expiration dans moins de ces jours.
    public var expiryDays: Int = 7

    public init(importantKeys: [String] = [], disconnectedHours: Double = 4, expiryDays: Int = 7) {
        self.importantKeys = importantKeys
        self.disconnectedHours = disconnectedHours
        self.expiryDays = expiryDays
    }
}

public struct WireGuardFinding: Equatable, Identifiable, Sendable {
    public enum Level: String, Sendable { case error, warning, info }
    public var id: String
    public var level: Level
    public var title: String
    public var detail: String
    /// Compte pour la sonde de Surveillance (sinon : avis du tableau de bord seulement).
    public var alerts: Bool

    public init(id: String, _ level: Level, _ title: String, _ detail: String, alerts: Bool = true) {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
        self.alerts = alerts
    }
}

public enum WireGuardServerAlerts {
    public static func findings(_ status: WireGuardServerStatus, rows: [WireGuardClientRow], settings: WireGuardWatchSettings,
                                knownKey: String?, now: Date) -> [WireGuardFinding] {
        var result: [WireGuardFinding] = []
        if status.dockerMissing {
            result.append(WireGuardFinding(id: "docker", .error, "Docker absent du serveur", "wg-easy tourne en conteneur\u{00A0}: rien à lire."))
            return result
        }
        guard let container = status.container else {
            result.append(WireGuardFinding(id: "conteneur", .error, "Conteneur wg-easy introuvable",
                                           "Aucun conteneur «\u{00A0}wg-easy\u{00A0}» sur le serveur (nom à vérifier dans les réglages de l’onglet)."))
            return result
        }
        if !container.isRunning {
            result.append(WireGuardFinding(id: "arret", .error, "Conteneur wg-easy arrêté", "État\u{00A0}: \(container.state). Aucun client ne peut se connecter."))
        }
        if let knownKey, let key = status.serverKey, key != knownKey {
            result.append(WireGuardFinding(id: "cle", .error, "Clé publique du serveur changée",
                                           "Tous les clients doivent recevoir une nouvelle configuration. Vérifier qu’il s’agit bien d’une réinstallation voulue."))
        }
        if status.edition == .v14 {
            result.append(WireGuardFinding(id: "v14", .info, "wg-easy 14 reconnue (wg0.json)",
                                           "Lecture seule par SSH. La migration vers la 15 se fait selon le guide officiel de wg-easy.", alerts: false))
        }
        if status.insecure == true {
            result.append(WireGuardFinding(id: "http", .warning, "Interface wg-easy en HTTP simple (INSECURE=true)",
                                           "Le mot de passe circule en clair sur le réseau local à chaque appel. HTTPS conseillé\u{00A0}; ne jamais exposer l’interface par une VIP.",
                                           alerts: false))
        }
        let important = Set(settings.importantKeys)
        for row in rows where important.contains(row.publicKey) && row.enabled && !row.isConnected(now: now) {
            let since = row.latestHandshake.map { now.timeIntervalSince($0) } ?? .infinity
            if since >= settings.disconnectedHours * 3_600 {
                let when = row.latestHandshake.map { "dernière poignée de main il y a \(RustDeskServerFormat.duration(Int(now.timeIntervalSince($0))))" } ?? "jamais connecté"
                result.append(WireGuardFinding(id: "deconnecte-" + row.id, .warning, "\(row.name) déconnecté", when + "."))
            }
        }
        for row in rows where row.enabled {
            guard let expires = row.expiresAt else { continue }
            let days = expires.timeIntervalSince(now) / 86_400
            if days < 0 {
                result.append(WireGuardFinding(id: "expire-" + row.id, .info, "\(row.name)\u{00A0}: accès expiré", "Expiré depuis le \(dayLabel(expires)).", alerts: false))
            } else if days < Double(settings.expiryDays) {
                result.append(WireGuardFinding(id: "expire-" + row.id, .warning, "\(row.name) expire bientôt", "Accès jusqu’au \(dayLabel(expires))."))
            }
        }
        return result
    }

    /// Problèmes comptés par la sonde « Serveur WireGuard ».
    public static func problems(_ findings: [WireGuardFinding]) -> [String] {
        findings.filter { $0.alerts && $0.level != .info }.map(\.title)
    }

    static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Mise à jour de l'image (avec retour arrière)

public enum WireGuardServerActionScript {
    /// Mise à jour de l'image wg-easy par docker compose : configuration sauvegardée (root seulement),
    /// image d'avant étiquetée, pull, up -d, vérification (conteneur en marche, wg show), sinon retour.
    public static func updateImage(container: String) throws -> String {
        let name = try RustDeskActionValidation.containerName(container)
        return RustDeskServerActionScript.prelude
            .replacingOccurrences(of: "# NetScope : action sur le serveur RustDesk, confirmée dans NetScope.",
                                  with: "# NetScope : mise à jour de wg-easy, confirmée dans NetScope.")
            .replacingOccurrences(of: "(Réglages › RustDesk)", with: "(Réglages › RustDesk, même compte)")
            + "\nS='\(name)'\n" + update
    }

    static let update = #"""
    command -v docker >/dev/null 2>&1 || { etape echec "Docker absent du serveur."; fin echec; }
    [ -n "$(dk inspect --format '{{.Name}}' "$S" 2>/dev/null)" ] || { etape echec "Conteneur $S introuvable."; fin echec; }
    lab() { dk inspect --format "{{index .Config.Labels \"$1\"}}" "$S" 2>/dev/null; }
    DIR=$(lab com.docker.compose.project.working_dir)
    PROJ=$(lab com.docker.compose.project)
    CFG=$(lab com.docker.compose.project.config_files)
    SVC=$(lab com.docker.compose.service)
    [ -n "$DIR" ] || { etape echec "wg-easy n’a pas été lancé par docker compose : mise à jour automatique non prise en charge."; fin echec; }
    # Seul le service de wg-easy est tiré et recréé (--no-deps) : les autres services du même compose n’y passent pas.
    case "$SVC" in
      ''|-*|*[!A-Za-z0-9._-]*) etape echec "Service compose de wg-easy introuvable (étiquette com.docker.compose.service) : rien n’est changé."; fin echec ;;
    esac
    if dkl compose version >/dev/null 2>&1; then DCV=2
    elif command -v docker-compose >/dev/null 2>&1; then DCV=1
    else etape echec "Ni « docker compose » ni « docker-compose » sur le serveur."; fin echec; fi
    dc() {
      dcn=$#
      set -f; dco=$IFS; IFS=,
      for dcf in $CFG; do set -- "$@" -f "$dcf"; done
      IFS=$dco; set +f
      dci=0; while [ $dci -lt $dcn ]; do set -- "$@" "$1"; shift; dci=$((dci+1)); done
      if [ -n "$PROJ" ]; then set -- -p "$PROJ" "$@"; fi
      set -- --project-directory "$DIR" "$@"
      if [ "$DCV" = 2 ]; then dkl compose "$@"
      elif [ "$DKDIRECT" = 1 ]; then timeout 900 docker-compose "$@" </dev/null
      else asroot timeout 900 docker-compose "$@"; fi
    }
    val dossier "$DIR"
    if dc config -q >/dev/null 2>&1; then etape ok "Compose relu sans erreur ($DIR)."
    else etape echec "Le compose de $DIR ne se lit pas (docker compose config) : rien n’est changé."; fin echec; fi
    STAMP=$(date +%Y%m%d-%H%M%S)
    DATA=$(dk inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/wireguard"}}{{.Source}}{{end}}{{end}}' "$S" 2>/dev/null)
    [ -n "$DATA" ] || { etape echec "Dossier /etc/wireguard du conteneur introuvable : rien n’est changé."; fin echec; }
    B="/var/backups/netscope-wgeasy-$STAMP.tar.gz"
    # Archive en 600 (umask 077) : elle contient les clés du serveur et des clients ; elle reste sur le serveur.
    if asroot mkdir -p /var/backups && asroot sh -c 'umask 077; exec tar -C "$1" -czf "$2" .' sh "$DATA" "$B" 2>/dev/null \
       && asroot chmod 600 "$B"; then etape ok "Configuration sauvegardée (lisible par root seulement) : $B"; val sauvegarde "$B"
    else etape echec "Sauvegarde de la configuration impossible : rien n’est changé."; fin echec; fi
    CLE1=$(dk exec "$S" wg show wg0 public-key 2>/dev/null)
    V1=$(lab org.opencontainers.image.version)
    val version_avant "$V1"
    IMG=$(dk inspect --format '{{.Config.Image}}' "$S" 2>/dev/null)
    IID=$(dk inspect --format '{{.Image}}' "$S" 2>/dev/null)
    REPO=$(printf '%s' "$IMG" | sed 's/:[^:/]*$//')
    RETOUR="$REPO:netscope-avant-$STAMP"
    if dk tag "$IID" "$RETOUR" >/dev/null 2>&1; then etape ok "Image actuelle étiquetée $RETOUR."; val image_retour "$RETOUR"
    else etape echec "Étiquette de retour impossible : rien n’est changé."; fin echec; fi
    if dc pull "$SVC" >/dev/null 2>&1; then etape ok "docker compose pull $SVC terminé."
    else etape echec "docker compose pull a échoué (réseau, registre) : rien n’est changé."; fin echec; fi
    NID=$(dk image inspect --format '{{.Id}}' "$IMG" 2>/dev/null)
    if [ "$NID" = "$IID" ]; then etape info "Déjà à jour : aucune nouvelle image, rien n’est redémarré."; val version_apres "$V1"; fin ok; fi
    if dc up -d --no-deps "$SVC" >/dev/null 2>&1; then etape ok "docker compose up -d $SVC terminé (autres services intacts)."; else etape attention "docker compose up -d $SVC a signalé une erreur."; fi
    verifier() {
      i=0
      while [ $i -lt 15 ]; do
        if [ "$(dk inspect --format '{{.State.Running}}' "$S" 2>/dev/null)" = true ] && dk exec "$S" wg show wg0 public-key >/dev/null 2>&1; then return 0; fi
        sleep 2; i=$((i+1))
      done
      return 1
    }
    if verifier; then
      etape ok "wg-easy tourne, interface wg0 active."
      val version_apres "$(lab org.opencontainers.image.version)"
      CLE2=$(dk exec "$S" wg show wg0 public-key 2>/dev/null)
      if [ -n "$CLE1" ] && [ "$CLE1" = "$CLE2" ]; then etape ok "Clé publique du serveur inchangée."
      else etape attention "Clé publique du serveur différente ou illisible : vérifier les clients (sauvegarde $B)."; fi
      fin ok
    fi
    etape echec "wg-easy ne repart pas après la mise à jour : retour à l’image précédente."
    if dk tag "$RETOUR" "$IMG" >/dev/null 2>&1 && dc up -d --no-deps "$SVC" >/dev/null 2>&1 && verifier; then
      etape ok "Image précédente remise ($RETOUR) : wg-easy tourne de nouveau."
      val retour ok
    else
      etape echec "Retour à l’image précédente impossible : intervention manuelle requise (sauvegarde $B, image $RETOUR)."
      val retour echec
    fi
    fin echec
    """#
}

// MARK: - SSH

extension RustDeskServerSSH {
    /// Lecture du serveur WireGuard (même compte et même sudo que le serveur RustDesk).
    public static func readWireGuard(_ account: RustDeskServerAccount, secret: String?, sudoPassword: String?, container: String,
                                     now: Date = Date()) async -> Result<WireGuardServerStatus, RustDeskServerReadError> {
        let script: String
        do { script = try WireGuardServerScript.read(container: container) } catch {
            return .failure(RustDeskServerReadError(kind: .account, detail: (error as? LocalizedError)?.errorDescription ?? "Nom de conteneur invalide."))
        }
        return await runDetail(account, secret: secret, sudoPassword: sudoPassword, script: script, timeout: 90)
            .map { WireGuardServerOutput.parse($0, readAt: now) }
    }

    /// Mise à jour confirmée de l'image wg-easy.
    public static func updateWireGuard(_ account: RustDeskServerAccount, secret: String?, sudoPassword: String?,
                                       container: String) async -> Result<RustDeskActionOutput, RustDeskServerReadError> {
        let script: String
        do { script = try WireGuardServerActionScript.updateImage(container: container) } catch {
            return .failure(RustDeskServerReadError(kind: .account, detail: (error as? LocalizedError)?.errorDescription ?? "Nom de conteneur invalide."))
        }
        return await runDetail(account, secret: secret, sudoPassword: sudoPassword, script: script, timeout: 1_800, outputLimit: 1_000_000)
            .map { RustDeskActionOutput.parse($0) }
    }

    /// Commande à coller dans Terminal (lecture ; aucun secret, première ligne vide pour sudo).
    public static func copyableWireGuardCommand(_ account: RustDeskServerAccount, container: String) -> String {
        var words = ["ssh", "-T"]
        if !account.jump.isEmpty { words += ["-J", account.jump] }
        if !account.keyPath.isEmpty { words += ["-i", account.keyPath] }
        if account.port != 22 { words += ["-p", String(account.port)] }
        words += ["--", account.destination]
        let script = (try? WireGuardServerScript.read(container: container)) ?? ""
        return RemoteShell.command(words) + " " + RemoteShell.quote(RustDeskServerDetailScript.remoteCommand) + " <<'NETSCOPE'\n\n" + script + "\nNETSCOPE\n"
    }
}
