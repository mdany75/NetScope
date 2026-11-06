import Foundation

// Note 87 (0.33.0) : serveur RustDesk, lecture seulement. Santé (durée de fonctionnement,
// processeur, mémoire, redémarrages), clé publique, empreinte des images Docker, et lectures à la
// demande avec sudo (mot de passe au Trousseau, passé sur l'entrée standard) : mises à jour du
// système, version de hbbs, journaux de hbbs et hbbr, copie du dossier de données. Aucune
// commande de ces scripts ne modifie le serveur.

// MARK: - Santé

/// Durée de fonctionnement, charge, processeur et mémoire du serveur (/proc).
public struct RustDeskServerHealth: Equatable, Sendable {
    public var uptimeSeconds: Int?
    /// Charge moyenne sur 1, 5 et 15 minutes.
    public var load: [Double]
    public var cpus: Int?
    /// Processeur occupé (%), mesuré sur une seconde.
    public var cpuPercent: Double?
    public var memoryTotalKB: Int64?
    public var memoryAvailableKB: Int64?

    public init(uptimeSeconds: Int? = nil, load: [Double] = [], cpus: Int? = nil, cpuPercent: Double? = nil,
                memoryTotalKB: Int64? = nil, memoryAvailableKB: Int64? = nil) {
        self.uptimeSeconds = uptimeSeconds
        self.load = load
        self.cpus = cpus
        self.cpuPercent = cpuPercent
        self.memoryTotalKB = memoryTotalKB
        self.memoryAvailableKB = memoryAvailableKB
    }

    /// Mémoire utilisée (fraction), si connue.
    public var memoryUsedFraction: Double? {
        guard let total = memoryTotalKB, total > 0, let available = memoryAvailableKB else { return nil }
        return min(1, max(0, Double(total - available) / Double(total)))
    }

    /// Section SANTE : « uptime=… », « charge=… », « cpus=… », « MemTotal:… », « cpu1=cpu … », « cpu2=cpu … ».
    public static func parse(_ lines: [String]) -> RustDeskServerHealth? {
        guard !lines.isEmpty else { return nil }
        var health = RustDeskServerHealth()
        var cpu1: [Int64] = [], cpu2: [Int64] = []
        for line in lines {
            if line.hasPrefix("uptime=") {
                health.uptimeSeconds = Double(line.dropFirst(7).trimmingCharacters(in: .whitespaces)).map { Int($0) }
            } else if line.hasPrefix("charge=") {
                health.load = line.dropFirst(7).split(separator: " ").compactMap { Double($0) }
            } else if line.hasPrefix("cpus=") {
                health.cpus = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("MemTotal:") {
                health.memoryTotalKB = Int64(line.dropFirst(9).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("MemAvailable:") {
                health.memoryAvailableKB = Int64(line.dropFirst(13).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("cpu1=") {
                cpu1 = cpuCounters(String(line.dropFirst(5)))
            } else if line.hasPrefix("cpu2=") {
                cpu2 = cpuCounters(String(line.dropFirst(5)))
            }
        }
        health.cpuPercent = cpuPercent(cpu1, cpu2)
        return health
    }

    /// « cpu  user nice system idle iowait irq softirq steal … » → compteurs.
    static func cpuCounters(_ line: String) -> [Int64] {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard words.first == "cpu" else { return [] }
        return words.dropFirst().compactMap { Int64($0) }
    }

    /// Part occupée entre deux relevés de /proc/stat (inactif = idle + iowait).
    static func cpuPercent(_ a: [Int64], _ b: [Int64]) -> Double? {
        guard a.count >= 4, b.count == a.count else { return nil }
        let count = min(a.count, 8)
        let totalA = a.prefix(count).reduce(0, +), totalB = b.prefix(count).reduce(0, +)
        let idleA = a[3] + (a.count > 4 ? a[4] : 0), idleB = b[3] + (b.count > 4 ? b[4] : 0)
        let total = totalB - totalA, idle = idleB - idleA
        guard total > 0, idle >= 0, idle <= total else { return nil }
        return Double(total - idle) / Double(total) * 100
    }
}

/// Conteneur inspecté : nombre de redémarrages, démarrage, image demandée et image réelle.
public struct RustDeskContainerDetail: Equatable, Sendable {
    public var name: String
    public var restartCount: Int
    public var startedAt: Date?
    /// Image demandée (« rustdesk/rustdesk-server:latest »).
    public var image: String
    /// Identifiant de l'image réellement utilisée (« sha256:… »).
    public var imageID: String

    public init(name: String, restartCount: Int, startedAt: Date? = nil, image: String, imageID: String) {
        self.name = name
        self.restartCount = restartCount
        self.startedAt = startedAt
        self.image = image
        self.imageID = imageID
    }

    /// « /hbbs|0|2026-11-03T08:12:44.123456789Z|rustdesk/rustdesk-server:latest|sha256:… ».
    public static func parse(_ line: String) -> RustDeskContainerDetail? {
        let fields = line.components(separatedBy: "|")
        guard fields.count >= 5, let restarts = Int(fields[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        var name = RustDeskServerOutput.clean(fields[0])
        if name.hasPrefix("/") { name.removeFirst() }
        return RustDeskContainerDetail(name: name, restartCount: restarts, startedAt: dockerDate(fields[2]),
                                       image: RustDeskServerOutput.clean(fields[3]), imageID: RustDeskServerOutput.clean(fields[4]))
    }

    /// Date de Docker (nanosecondes coupées) ; « 0001-01-01T00:00:00Z » : jamais démarré.
    static func dockerDate(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if let dot = value.firstIndex(of: ".") {
            let tail = value[dot...].drop { $0 == "." || $0.isNumber }
            value = String(value[..<dot]) + tail
        }
        guard let date = ISO8601DateFormatter().date(from: value), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}

/// Image locale : identifiant et empreintes de dépôt (« rustdesk/rustdesk-server@sha256:… »).
public struct RustDeskImageDigest: Equatable, Sendable {
    public var imageID: String
    public var repoDigests: [String]

    public init(imageID: String, repoDigests: [String]) {
        self.imageID = imageID
        self.repoDigests = repoDigests
    }

    public static func parse(_ line: String) -> RustDeskImageDigest? {
        let fields = line.components(separatedBy: "|")
        guard fields.count >= 2, fields[0].hasPrefix("sha256:") else { return nil }
        return RustDeskImageDigest(imageID: RustDeskServerOutput.clean(fields[0]),
                                   repoDigests: fields[1].split(separator: " ").map { RustDeskServerOutput.clean(String($0)) })
    }

    /// Empreinte « sha256:… » d'un dépôt donné (« rustdesk/rustdesk-server »).
    public func digest(repository: String = RustDeskVersionCheck.serverRepository) -> String? {
        for entry in repoDigests {
            guard let at = entry.firstIndex(of: "@") else { continue }
            let repo = entry[..<at].lowercased()
            if repo == repository || repo.hasSuffix("/" + repository) || repo == "docker.io/" + repository {
                return String(entry[entry.index(after: at)...])
            }
        }
        return nil
    }
}

/// Clé publique du serveur (id_ed25519.pub) : lue, illisible, ou absente.
public enum RustDeskPublicKey: Equatable, Sendable {
    case key(String)
    case unreadable
    case unknown

    public var value: String? {
        if case .key(let text) = self { return text }
        return nil
    }

    static func parse(_ lines: [String]?) -> RustDeskPublicKey {
        guard let lines else { return .unknown }
        for line in lines {
            if line.hasPrefix("cle=") {
                let key = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                // Clé ed25519 en base 64 (44 caractères) : rien d'autre n'est gardé.
                guard key.count <= 100, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }),
                      !key.isEmpty else { return .unknown }
                return .key(key)
            }
            if line == "ETAT illisible" { return .unreadable }
        }
        return .unknown
    }
}

// MARK: - Mises à jour du système

/// Mises à jour du système lues sans rien installer (apt list --upgradable, dnf -C check-update).
public struct RustDeskSystemUpdates: Equatable, Sendable {
    /// « apt », « dnf » ou vide (gestionnaire inconnu).
    public var manager: String
    public var packages: [String]
    /// Paquets venus d'un dépôt de sécurité.
    public var security: [String]
    public var rebootRequired: Bool
    /// Paquets qui demandent le redémarrage (/var/run/reboot-required.pkgs).
    public var rebootPackages: [String]
    /// Date des listes de paquets (apt) : la lecture ne les rafraîchit jamais.
    public var listsDate: Date?

    public init(manager: String = "", packages: [String] = [], security: [String] = [], rebootRequired: Bool = false,
                rebootPackages: [String] = [], listsDate: Date? = nil) {
        self.manager = manager
        self.packages = packages
        self.security = security
        self.rebootRequired = rebootRequired
        self.rebootPackages = rebootPackages
        self.listsDate = listsDate
    }

    /// Sections MAJ et REDEMARRAGE de la lecture détaillée.
    public static func parse(updates: [String]?, reboot: [String]?) -> RustDeskSystemUpdates? {
        guard updates != nil || reboot != nil else { return nil }
        var result = RustDeskSystemUpdates()
        var inSecurity = false
        var securityNames = Set<String>()
        for line in updates ?? [] {
            if line.hasPrefix("GESTIONNAIRE ") {
                result.manager = String(line.dropFirst(13)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("listes=") {
                if let epoch = Double(line.dropFirst(7).trimmingCharacters(in: .whitespaces)), epoch > 0 {
                    result.listsDate = Date(timeIntervalSince1970: epoch)
                }
                continue
            }
            if line == "SECURITE" {
                inSecurity = true
                continue
            }
            if result.manager == "apt" {
                // « openssl/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: …] ».
                guard let slash = line.firstIndex(of: "/"), line.contains("upgradable") else { continue }
                let name = RustDeskServerOutput.clean(String(line[..<slash]))
                result.packages.append(name)
                let origin = line[line.index(after: slash)...].split(separator: " ").first ?? ""
                if origin.contains("-security") { securityNames.insert(name) }
            } else if result.manager == "dnf" {
                let words = line.split(separator: " ", omittingEmptySubsequences: true)
                if inSecurity {
                    // « FEDORA-2026-1234 Important/Sec. openssl-1:3.2.2-1.fc41.x86_64 ».
                    guard words.count >= 3, words[1].contains("Sec") else { continue }
                    securityNames.insert(dnfName(String(words[2])))
                } else {
                    // « openssl.x86_64  1:3.2.2-1.fc41  updates ».
                    guard words.count == 3, words[0].contains(".") else { continue }
                    let full = String(words[0])
                    result.packages.append(RustDeskServerOutput.clean(String(full[..<(full.lastIndex(of: ".") ?? full.endIndex)])))
                }
            }
        }
        result.security = result.packages.filter { securityNames.contains($0) }
        if result.manager == "dnf" {
            // updateinfo nomme parfois un paquet absent de check-update (déjà à jour ailleurs) : ignoré.
            result.security = Array(Set(result.security)).sorted()
        }
        for line in reboot ?? [] {
            if line == "requis" { result.rebootRequired = true } else if line != "non" {
                result.rebootPackages.append(RustDeskServerOutput.clean(line))
            }
        }
        return result
    }

    /// « openssl-1:3.2.2-1.fc41.x86_64 » → « openssl ».
    static func dnfName(_ text: String) -> String {
        var parts = text.split(separator: "-").map(String.init)
        while parts.count > 1, let last = parts.last, last.first?.isNumber == true || last.contains(":") || last.contains(".fc") || last.contains(".el") {
            parts.removeLast()
        }
        return parts.joined(separator: "-")
    }
}

/// Résultat de la lecture détaillée (avec sudo si besoin), à la demande ou une fois par jour.
public struct RustDeskServerReading: Equatable, Sendable {
    public var readAt: Date
    /// sudo : « ok », « root », « refuse » (mot de passe absent ou refusé), « absent ».
    public var sudo: String
    public var updates: RustDeskSystemUpdates?
    /// Sortie de « hbbs --version » (« hbbs 1.1.14 ») ramenée au numéro.
    public var hbbsVersion: String?
    public var containers: [RustDeskContainerDetail]
    public var images: [RustDeskImageDigest]
    public var publicKey: RustDeskPublicKey

    public init(readAt: Date, sudo: String = "", updates: RustDeskSystemUpdates? = nil, hbbsVersion: String? = nil,
                containers: [RustDeskContainerDetail] = [], images: [RustDeskImageDigest] = [], publicKey: RustDeskPublicKey = .unknown) {
        self.readAt = readAt
        self.sudo = sudo
        self.updates = updates
        self.hbbsVersion = hbbsVersion
        self.containers = containers
        self.images = images
        self.publicKey = publicKey
    }

    public static func parse(_ text: String, readAt: Date) -> RustDeskServerReading {
        let parts = RustDeskServerOutput.sections(text)
        var detail = RustDeskServerReading(readAt: readAt)
        detail.sudo = parts["ACCES"]?.lines.first.map { $0.replacingOccurrences(of: "SUDO ", with: "") } ?? ""
        detail.updates = RustDeskSystemUpdates.parse(updates: parts["MAJ"]?.lines, reboot: parts["REDEMARRAGE"]?.lines)
        detail.hbbsVersion = (parts["VERSION"]?.lines ?? []).lazy.compactMap(RustDeskVersionCheck.versionNumber).first
        detail.containers = (parts["INSPECT"]?.lines ?? []).compactMap(RustDeskContainerDetail.parse)
        detail.images = (parts["IMAGES"]?.lines ?? []).compactMap(RustDeskImageDigest.parse)
        detail.publicKey = RustDeskPublicKey.parse(parts["CLE"]?.lines)
        return detail
    }
}

// MARK: - Scripts à la demande

/// Scripts fixes lus avec sudo si nécessaire. Le mot de passe (première ligne de l'entrée) reste
/// dans une variable non exportée du shell distant ; « sudo -k -S » le lit à chaque commande (jamais
/// d'élévation gardée en cache), « printf » est intégré au shell (rien dans la liste des processus).
public enum RustDeskServerDetailScript {
    public static let remoteCommand = #"sh -c 'IFS= read -r NETSCOPE_MDP; eval "$(cat)"'"#

    /// En-tête commun : fonctions « asroot » (sudo seulement si nécessaire) et « dk » (docker).
    static let prelude = #"""
    # NetScope : lecture seule du serveur RustDesk ; aucune commande ne modifie le serveur.
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    D=/opt/rustdesk
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
    elif ! command -v sudo >/dev/null 2>&1; then echo 'SUDO absent'
    elif asroot true >/dev/null 2>&1; then echo 'SUDO ok'
    else echo 'SUDO refuse'; NETSCOPE_MDP=
    fi
    NOMS=
    if command -v docker >/dev/null 2>&1; then
      NOMS=$(dk ps --all --format '{{.Names}}' 2>/dev/null | grep -Ei 'hbbs|hbbr|rustdesk')
    fi
    """#

    /// Mises à jour du système, version de hbbs, conteneurs et images, clé publique.
    public static let details: String = prelude + "\n" + #"""
    section MAJ
    if command -v apt >/dev/null 2>&1; then
      echo 'GESTIONNAIRE apt'
      printf 'listes=%s\n' "$(stat -c %Y /var/lib/apt/lists 2>/dev/null)"
      timeout 60 apt list --upgradable 2>/dev/null | grep -v '^Listing'
    elif command -v dnf >/dev/null 2>&1; then
      echo 'GESTIONNAIRE dnf'
      timeout 90 dnf -q -C check-update 2>/dev/null
      echo 'SECURITE'
      timeout 90 dnf -q -C updateinfo list --security 2>/dev/null
    fi
    section REDEMARRAGE
    if [ -e /var/run/reboot-required ]; then
      echo 'requis'
      head -n 20 /var/run/reboot-required.pkgs 2>/dev/null
    elif command -v needs-restarting >/dev/null 2>&1; then
      timeout 30 needs-restarting -r >/dev/null 2>&1
      if [ $? = 1 ]; then echo 'requis'; else echo 'non'; fi
    else
      echo 'non'
    fi
    section VERSION
    if command -v hbbs >/dev/null 2>&1; then
      timeout 5 hbbs --version </dev/null 2>&1 | head -n 2
    else
      for n in $NOMS; do
        case "$n" in *hbbs*) dk exec "$n" hbbs --version 2>&1 | head -n 2; break ;; esac
      done
    fi
    section INSPECT
    for n in $NOMS; do
      dk inspect --format '{{.Name}}|{{.RestartCount}}|{{.State.StartedAt}}|{{.Config.Image}}|{{.Image}}' "$n" 2>/dev/null
    done
    section IMAGES
    for i in $(for n in $NOMS; do dk inspect --format '{{.Image}}' "$n" 2>/dev/null; done | sort -u); do
      dk image inspect --format '{{.Id}}|{{join .RepoDigests " "}}' "$i" 2>/dev/null
    done
    section CLE
    for f in "$D/data/id_ed25519.pub" "$D/id_ed25519.pub"; do
      if [ -r "$f" ]; then printf 'cle=%s\n' "$(head -c 200 "$f")"; break
      elif asroot test -e "$f" 2>/dev/null; then printf 'cle=%s\n' "$(asroot head -c 200 "$f" 2>/dev/null)"; break
      fi
    done
    NETSCOPE_MDP=
    section FIN
    """#

    /// Lignes de journal lues par service.
    public static let logLines = 400

    /// Journaux de hbbs et hbbr : docker logs, sinon journalctl (services rustdesk-hbbs/hbbr).
    public static let logs: String = prelude + "\n" + #"""
    for s in hbbs hbbr; do
      section "JOURNAL_$s"
      n=$(printf '%s\n' $NOMS | grep -i "$s" | head -n 1)
      if [ -n "$n" ]; then
        dk logs --timestamps --tail 400 "$n" 2>&1 | tail -n 400
      elif command -v journalctl >/dev/null 2>&1; then
        timeout 20 journalctl -u "rustdesk-$s" --no-pager -o short-iso -n 400 2>/dev/null || asroot timeout 20 journalctl -u "rustdesk-$s" --no-pager -o short-iso -n 400 2>/dev/null
      fi
    done
    NETSCOPE_MDP=
    section FIN
    """#

    /// Copie du dossier de données (clés et base) en tar.gz, base 64, sur la sortie seulement :
    /// rien n'est écrit sur le serveur. Dossier : volume monté sur /root du conteneur hbbs, sinon
    /// /opt/rustdesk/data, /opt/rustdesk, /var/lib/rustdesk-server.
    public static let backup: String = prelude + "\n" + #"""
    DATA=
    for n in $NOMS; do
      case "$n" in *hbbs*)
        m=$(dk inspect --format '{{range .Mounts}}{{if eq .Destination "/root"}}{{.Source}}{{end}}{{end}}' "$n" 2>/dev/null)
        if [ -n "$m" ]; then DATA=$m; fi ;;
      esac
    done
    if [ -z "$DATA" ]; then
      for d in "$D/data" "$D" /var/lib/rustdesk-server; do
        if asroot test -e "$d/id_ed25519.pub" 2>/dev/null; then DATA=$d; break; fi
      done
    fi
    section DOSSIER
    printf '%s\n' "$DATA"
    section ARCHIVE
    if [ -n "$DATA" ]; then
      F=
      for f in id_ed25519 id_ed25519.pub db_v2.sqlite3 db_v2.sqlite3-wal db_v2.sqlite3-shm; do
        if asroot test -e "$DATA/$f" 2>/dev/null; then F="$F $f"; fi
      done
      asroot tar -C "$DATA" -czf - $F 2>/dev/null | base64
    fi
    NETSCOPE_MDP=
    section FIN
    """#

    /// Commandes du serveur citées par les scripts : aucune ne doit modifier quoi que ce soit
    /// (vérifié par les tests : pas de rm, mv, cp, docker pull/stop/restart/rm, apt install…).
    public static let forbiddenWords = ["rm ", "mv ", "cp ", " pull", " stop", " restart", " start ", " kill", "apt-get", "apt install",
                                        "apt upgrade", "apt update", "dnf upgrade", "dnf install", "systemctl", "reboot ", "shutdown",
                                        "chmod", "chown", "tee ", " sqlite3 ", "compose"]
}

// MARK: - Journaux

/// Ligne de journal de hbbs ou hbbr.
public struct RustDeskLogLine: Equatable, Identifiable, Sendable {
    public var id: Int
    public var service: String
    public var date: Date?
    /// « INFO », « WARN », « ERROR », « DEBUG » ou vide.
    public var level: String
    public var text: String

    public init(id: Int, service: String, date: Date?, level: String, text: String) {
        self.id = id
        self.service = service
        self.date = date
        self.level = level
        self.text = text
    }

    /// Sortie du script des journaux : sections « JOURNAL_hbbs » et « JOURNAL_hbbr ».
    public static func parse(_ output: String) -> [RustDeskLogLine] {
        let parts = RustDeskServerOutput.sections(output)
        var lines: [RustDeskLogLine] = []
        for service in ["hbbs", "hbbr"] {
            for raw in parts["JOURNAL_" + service]?.lines ?? [] {
                lines.append(parse(raw, service: service, id: lines.count))
            }
        }
        return lines.sorted { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
    }

    /// « 2026-11-06T13:02:11.123456789Z [2026-11-06 13:02:11.123 +00:00] INFO [src/…] texte ».
    static func parse(_ raw: String, service: String, id: Int) -> RustDeskLogLine {
        var text = RemoteShell.sanitizedTitle(raw, limit: 600)
        var date: Date?
        if let space = text.firstIndex(of: " "), let parsed = RustDeskContainerDetail.dockerDate(String(text[..<space])) {
            date = parsed
            text = String(text[text.index(after: space)...])
        }
        var level = ""
        for candidate in ["ERROR", "WARN", "INFO", "DEBUG", "TRACE"] where text.contains(" \(candidate) ") || text.hasPrefix(candidate + " ") {
            level = candidate
            break
        }
        return RustDeskLogLine(id: id, service: service, date: date, level: level, text: text)
    }

    /// Filtre : texte cherché (sans casse) et ID RustDesk (chiffres, espaces ignorés).
    public static func filter(_ lines: [RustDeskLogLine], search: String, id: String, service: String? = nil) -> [RustDeskLogLine] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let digits = id.filter(\.isNumber)
        return lines.filter { line in
            if let service, line.service != service { return false }
            if !query.isEmpty, line.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
            if !digits.isEmpty, !line.text.filter({ !$0.isWhitespace }).contains(digits) { return false }
            return true
        }
    }
}

// MARK: - Sauvegarde

/// Archive reçue par le script de sauvegarde.
public enum RustDeskBackupArchive {
    /// Dossier lu et archive tar.gz décodée ; nil si la sortie n'en contient pas.
    public static func decode(_ output: String) -> (folder: String, archive: Data)? {
        let parts = RustDeskServerOutput.sections(output)
        let folder = parts["DOSSIER"]?.lines.first.map(RustDeskServerOutput.clean) ?? ""
        let base64 = (parts["ARCHIVE"]?.lines ?? []).joined()
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.count > 20,
              data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        return (folder, data)
    }
}
