import Foundation

// Note 6 (suite, 0.26.2) : tableau de bord du serveur RustDesk Server OSS (hbbs + hbbr), en
// lecture seule. Une seule connexion /usr/bin/ssh au serveur ; le script de collecte, FIXE (aucune
// valeur saisie n'y est jamais insérée), passe par l'entrée standard de ssh. Il ne fait que lire :
// consoles texte de hbbr (127.0.0.1:21117) et de hbbs (127.0.0.1:21115), processus, conteneurs
// (seulement si le compte est déjà dans le groupe docker), paquets, disque, sauvegarde et nombre de
// postes enregistrés (sqlite3, seulement si la base est lisible). Jamais de sudo.
//
// Consoles (code source de rustdesk-server, src/relay_server.rs et src/rendezvous_server.rs) :
// une commande texte par connexion TCP depuis 127.0.0.1, réponse en texte, puis fermeture. Les
// mêmes commandes AVEC argument modifient le serveur (listes noires, débits, relais, « pr - »
// efface la liste des demandes…) : seule une liste blanche stricte est permise, deux fois
// vérifiée (ici et dans le script lui-même).

// MARK: - Commandes de console permises

/// Commandes des consoles de hbbr et hbbs que NetScope a le droit d'envoyer (lecture seule).
public enum RustDeskConsoleCommand {
    /// Console de hbbr (relais).
    public static let relayPort = 21117
    /// Console de hbbs (serveur d'ID) : l'écouteur du test NAT.
    public static let idPort = 21115

    /// hbbr : « u » (sessions relayées en cours), « tb » et « sb » sans argument (débits permis).
    public static let relayCommands: Set<String> = ["u", "tb", "sb"]
    /// hbbs : « h » (aide, pour savoir si « pr » existe) et « rs » sans argument (relais annoncés).
    public static let idCommands: Set<String> = ["h", "rs"]
    /// Taille de page la plus grande demandée à « pr <début> <taille> ».
    public static let maxPageSize = 100

    /// Vrai seulement pour une commande de lecture de la liste blanche : « u », « tb », « sb »
    /// (hbbr) ; « h », « rs », « pr <début> <taille> » en chiffres (hbbs). Tout le reste est
    /// refusé : arguments de modification, « pr - » (efface), « aur », « rg », « ib », « ic »…
    public static func isAllowed(port: Int, command: String) -> Bool {
        switch port {
        case relayPort:
            return relayCommands.contains(command)
        case idPort:
            if idCommands.contains(command) { return true }
            let words = command.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 3, words[0] == "pr" else { return false }
            guard let start = Int(words[1]), let size = Int(words[2]),
                  words[1].allSatisfy({ $0.isASCII && $0.isNumber }), words[2].allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return false
            }
            return start >= 0 && (1...maxPageSize).contains(size)
        default:
            return false
        }
    }
}

// MARK: - Script de collecte

/// Script de collecte envoyé tel quel au serveur (aucune interpolation de valeur saisie).
public enum RustDeskServerScript {
    /// Dossier du serveur (docker-compose, data/ : base et clés).
    public static let serverDirectory = "/opt/rustdesk"
    /// Marqueur de section : « @@NETSCOPE <NOM>@@ ».
    public static let sectionPrefix = "@@NETSCOPE "
    /// Code de retour de la section : « @@STATUT <n>@@ ».
    public static let statusPrefix = "@@STATUT "
    /// Demandes de connexion lues au plus (les plus récentes).
    public static let maxPunchRequests = 500

    /// Le script. POSIX sh ; lu en entier par « eval "$(cat)" » avant de s'exécuter, si bien
    /// qu'aucune commande ne peut consommer la suite du script par son entrée standard.
    public static let text: String = #"""
    # NetScope : lecture seule de l’état du serveur RustDesk (hbbs et hbbr), sans élévation ni écriture.
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    D=/opt/rustdesk
    section() { printf '\n@@NETSCOPE %s@@\n' "$1"; }
    statut() { printf '\n@@STATUT %s@@\n' "$1"; }

    # Client TCP local, vers 127.0.0.1 seulement : nc, sinon bash (/dev/tcp), sinon python3.
    CLIENT=aucun
    if command -v nc >/dev/null 2>&1; then CLIENT=nc
    elif command -v bash >/dev/null 2>&1; then CLIENT=bash
    elif command -v python3 >/dev/null 2>&1; then CLIENT=python3
    fi

    # Une commande de console, de la liste blanche seulement (sinon refus, code 64).
    console() {
      case "$1:$2" in
        21117:u|21117:tb|21117:sb|21115:h|21115:rs) ;;
        "21115:pr "[0-9]*" "[0-9]*)
          case "$2" in *[!0-9pr\ ]*) return 64 ;; esac ;;
        *) return 64 ;;
      esac
      case "$CLIENT" in
        nc) printf '%s' "$2" | timeout 5 nc -w 3 127.0.0.1 "$1" 2>/dev/null ;;
        bash) timeout 5 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1; printf "%s" "$2" >&3; cat <&3' netscope "$1" "$2" 2>/dev/null ;;
        python3) timeout 5 python3 -c 'import socket,sys
    s=socket.create_connection(("127.0.0.1",int(sys.argv[1])),3)
    s.sendall(sys.argv[2].encode())
    s.settimeout(3)
    while True:
        d=s.recv(65536)
        if not d: break
        sys.stdout.write(d.decode("utf-8","replace"))' "$1" "$2" 2>/dev/null ;;
        *) return 127 ;;
      esac
    }

    section META
    printf 'hote=%s\n' "$(hostname 2>/dev/null)"
    printf 'utilisateur=%s\n' "$(id -un 2>/dev/null)"
    printf 'heure=%s\n' "$(date -u +%s)"
    printf 'systeme=%s\n' "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"')"
    printf 'client=%s\n' "$CLIENT"

    section PROCESSUS
    ps -eo etimes=,pid=,comm=,args= 2>/dev/null | awk '$3=="hbbs" || $3=="hbbr"'

    section DOCKER
    if ! command -v docker >/dev/null 2>&1; then
      echo 'IGNORE docker-absent'
    elif [ "$(id -u)" = 0 ] || id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      timeout 5 docker ps --all --format '{{.Names}}\t{{.Image}}\t{{.Status}}' </dev/null 2>/dev/null | grep -Ei 'hbbs|hbbr|rustdesk'
    else
      echo 'IGNORE groupe-docker'
    fi

    section PAQUETS
    if command -v dpkg-query >/dev/null 2>&1; then
      dpkg-query -W -f='${Package}\t${Version}\n' 'rustdesk-server*' 2>/dev/null
    fi

    section DISQUE
    df -Pk "$D/data" 2>/dev/null || df -Pk "$D" 2>/dev/null || df -Pk / 2>/dev/null
    printf 'du=%s\n' "$(du -sk "$D/data" 2>/dev/null | awk '{print $1}')"

    section SAUVEGARDE
    find "$D" -maxdepth 3 -type f \( -iname '*backup*' -o -iname '*sauvegarde*' -o -iname '*.bak' -o -iname '*.tar.gz' -o -iname '*.tgz' \) -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -rn | head -n 3

    section POSTES
    DB="$D/data/db_v2.sqlite3"
    if [ ! -e "$DB" ]; then echo 'ETAT introuvable'
    elif [ ! -r "$DB" ]; then echo 'ETAT illisible'
    elif ! command -v sqlite3 >/dev/null 2>&1; then echo 'ETAT sans-sqlite3'
    else
      echo 'ETAT ok'
      timeout 5 sqlite3 -readonly "$DB" 'SELECT count(*) FROM peer;' </dev/null 2>&1 | head -n 2
    fi

    section HBBR_U
    console 21117 u
    statut $?
    section HBBR_TB
    console 21117 tb
    statut $?
    section HBBR_SB
    console 21117 sb
    statut $?
    section HBBS_AIDE
    console 21115 h
    statut $?
    section HBBS_RS
    console 21115 rs
    statut $?

    # Nombre de demandes gardées par hbbs (de la plus ancienne à la plus récente) : recherche
    # exponentielle puis dichotomique avec « pr N 1 », qui ne fait que lire.
    section HBBS_NOMBRE
    n=0
    if [ -n "$(console 21115 'pr 0 1')" ]; then
      lo=0
      hi=1
      while [ "$hi" -le 2000000 ] && [ -n "$(console 21115 "pr $hi 1")" ]; do lo=$hi; hi=$((hi * 2)); done
      while [ $((hi - lo)) -gt 1 ]; do
        mid=$(((lo + hi) / 2))
        if [ -n "$(console 21115 "pr $mid 1")" ]; then lo=$mid; else hi=$mid; fi
      done
      n=$hi
    fi
    echo "$n"

    # Les 500 plus récentes, par pages de 100.
    section HBBS_PR
    s=$((n - 500))
    if [ "$s" -lt 0 ]; then s=0; fi
    while [ "$s" -lt "$n" ]; do
      console 21115 "pr $s 100"
      s=$((s + 100))
    done

    section FIN
    """#

    /// Commandes de console écrites dans le script (« console <port> <commande> ») ; une variable
    /// du shell (« $hi », « $s »…) devient « 0 » : sert au test de la liste blanche.
    public static func consoleCalls(in script: String = text) -> [(port: Int, command: String)] {
        var calls: [(Int, String)] = []
        for raw in script.components(separatedBy: "\n") {
            var line = Substring(raw)
            while let range = line.range(of: "console ") {
                // Seulement l'appel de la fonction (début de ligne ou « $( »), pas sa définition.
                let before = line[..<range.lowerBound]
                let tail = line[range.upperBound...]
                line = tail
                guard before.trimmingCharacters(in: .whitespaces).isEmpty || before.hasSuffix("$(") else { continue }
                let parts = tail.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let port = Int(parts[0]) else { continue }
                var argument = String(parts[1])
                if let quote = argument.first, quote == "'" || quote == "\"" {
                    argument.removeFirst()
                    guard let end = argument.firstIndex(of: quote) else { continue }
                    argument = String(argument[..<end])
                } else {
                    argument = String(argument.prefix { $0 != " " && $0 != ")" })
                }
                let resolved = argument.replacingOccurrences(of: #"\$[a-z_]+"#, with: "0", options: .regularExpression)
                calls.append((port, resolved))
            }
        }
        return calls
    }
}

// MARK: - Compte SSH du serveur

/// Compte SSH du serveur : « utilisateur@hôte[:port] », clé et rebonds facultatifs (repris d'une
/// connexion SSH du carnet).
public struct RustDeskServerAccount: Codable, Equatable, Sendable {
    public var user: String
    public var host: String
    public var port: Int
    /// Clé privée (chemin seulement, jamais copiée).
    public var keyPath: String
    /// Hôtes de rebond (valeur de -J), déjà validés par `SSHJumpChain`.
    public var jump: String

    public init(user: String, host: String, port: Int = 22, keyPath: String = "", jump: String = "") {
        self.user = user
        self.host = host
        self.port = port
        self.keyPath = keyPath
        self.jump = jump
    }

    /// « admin@serveur », « admin@serveur:2222 », « ssh://admin@serveur » (validation stricte).
    public static func parse(_ text: String) throws -> RustDeskServerAccount {
        let address = try QuickLoginAddress.parse(text)
        guard !address.user.isEmpty else { throw RemoteValidationError.invalidUser("") }
        return RustDeskServerAccount(user: address.user, host: address.host, port: address.port ?? 22)
    }

    /// Compte d'une connexion SSH du carnet (nil pour un autre protocole ou sans utilisateur).
    public init?(connection: RemoteConnection) {
        guard connection.proto == .ssh, !connection.username.trimmingCharacters(in: .whitespaces).isEmpty,
              let valid = try? connection.validated() else { return nil }
        self.init(user: valid.username, host: valid.host, port: valid.port, keyPath: valid.identityFile, jump: valid.proxyJump)
    }

    /// Valeurs revalidées (défense en profondeur avant de lancer ssh).
    public func validated() throws -> RustDeskServerAccount {
        var copy = self
        copy.host = try RemoteValidator.validateHost(host)
        copy.user = try RemoteValidator.validateUser(user)
        guard !copy.user.isEmpty else { throw RemoteValidationError.invalidUser(user) }
        try RemoteValidator.validatePort(port)
        copy.jump = try SSHJumpChain.normalized(jump)
        let key = keyPath.trimmingCharacters(in: .whitespaces)
        copy.keyPath = key.isEmpty ? "" : try QuickLogin.validateKeyPath(key)
        return copy
    }

    /// « admin@assistance.exemple.ca » (IPv6 entre crochets).
    public var destination: String {
        user + "@" + host
    }

    /// « admin@assistance.exemple.ca:2222 » ; le port 22 n'est pas écrit.
    public var label: String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return user + "@" + shownHost + (port == 22 ? "" : ":\(port)")
    }
}

// MARK: - Commande ssh

/// Construction de la commande ssh (pure, testée) et lancement.
public enum RustDeskServerSSH {
    public static let executable = "/usr/bin/ssh"
    /// Commande distante : le script est lu en entier sur l'entrée standard, puis exécuté.
    public static let remoteCommand = #"sh -c 'eval "$(cat)"'"#
    /// Délai de connexion SSH et délai total de la lecture (secondes).
    public static let connectTimeout = 10
    public static let totalTimeout: TimeInterval = 60

    /// Arguments de ssh, en tableau (jamais une chaîne passée à un shell) : options, puis « -- »,
    /// la destination et la commande distante fixe. Aucun secret : le mot de passe éventuel passe
    /// par SSH_ASKPASS. `hasSecret` faux : clés et agent seulement (BatchMode=yes).
    public static func arguments(_ account: RustDeskServerAccount, hasSecret: Bool,
                                 connectTimeout: Int = connectTimeout) -> [String] {
        var args = [
            "-T",
            "-o", "BatchMode=\(hasSecret ? "no" : "yes")",
            "-o", "ConnectTimeout=\(max(1, connectTimeout))",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "RequestTTY=no",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
        ]
        if let hops = try? SSHJumpChain.normalized(account.jump), !hops.isEmpty { args += ["-J", hops] }
        if !account.keyPath.isEmpty {
            args += ["-i", (account.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        if account.port != 22 { args += ["-p", String(account.port)] }
        args += ["--", account.destination, remoteCommand]
        return args
    }

    /// Environnement de ssh : script SSH_ASKPASS forcé quand un secret existe (le secret est ajouté
    /// au lancement seulement, dans NETSCOPE_SSH_SECRET, jamais dans les arguments ni sur le disque).
    public static func environment(askpass: URL?) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "C"]
        if let askpass {
            env["SSH_ASKPASS"] = askpass.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
        }
        return env
    }

    /// Script SSH_ASKPASS (sans secret) : « no » à la question d'un serveur inconnu ou changé
    /// (jamais le mot de passe), le secret sinon.
    public static let askpassScript = """
    #!/bin/sh
    case "$1" in
      *"continue connecting"*|*"(yes/no"*) echo no ;;
      *) printf '%s\\n' "$NETSCOPE_SSH_SECRET" ;;
    esac
    """ + "\n"

    /// Ligne affichée, sans secret : « ssh -p 2222 -- admin@serveur 'sh -c …' < script ».
    public static func displayCommand(_ account: RustDeskServerAccount) -> String {
        var words = ["ssh", "-T"]
        if !account.jump.isEmpty { words += ["-J", account.jump] }
        if !account.keyPath.isEmpty { words += ["-i", account.keyPath] }
        if account.port != 22 { words += ["-p", String(account.port)] }
        words += ["--", account.destination]
        return RemoteShell.command(words) + " " + RemoteShell.quote(remoteCommand) + " < collecte-rustdesk.sh"
    }

    /// Commande complète à coller dans Terminal : la même connexion, le script en document
    /// intégré (« << 'NETSCOPE' », sans aucune substitution). Jamais de secret.
    public static func copyableCommand(_ account: RustDeskServerAccount) -> String {
        var words = ["ssh", "-T"]
        if !account.jump.isEmpty { words += ["-J", account.jump] }
        if !account.keyPath.isEmpty { words += ["-i", account.keyPath] }
        if account.port != 22 { words += ["-p", String(account.port)] }
        words += ["--", account.destination]
        return RemoteShell.command(words) + " " + RemoteShell.quote(remoteCommand) + " <<'NETSCOPE'\n"
            + RustDeskServerScript.text + "\nNETSCOPE\n"
    }

    /// Lit l'état du serveur : une connexion ssh, le script sur l'entrée standard, délai total borné.
    public static func run(_ account: RustDeskServerAccount, secret: String?, timeout: TimeInterval = totalTimeout,
                           now: @escaping @Sendable () -> Date = { Date() }) async -> Result<RustDeskServerStatus, RustDeskServerReadError> {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(RustDeskServerReadError(kind: .launch, detail: "/usr/bin/ssh introuvable sur ce Mac."))
        }
        let valid: RustDeskServerAccount
        do {
            valid = try account.validated()
        } catch {
            return .failure(RustDeskServerReadError(kind: .account, detail: (error as? LocalizedError)?.errorDescription ?? "Compte SSH invalide."))
        }
        var askpassURL: URL?
        var temporary: URL?
        if let secret, !secret.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-rd-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let script = folder.appendingPathComponent("askpass.sh")
                try Data(askpassScript.utf8).write(to: script)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                askpassURL = script
                temporary = folder
            } catch {
                return .failure(RustDeskServerReadError(kind: .launch, detail: "Préparation impossible\u{00A0}: \(error.localizedDescription)"))
            }
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        var env = environment(askpass: askpassURL)
        if let secret, askpassURL != nil { env["NETSCOPE_SSH_SECRET"] = secret }
        let result = await ProcessRunner.run(executable, arguments(valid, hasSecret: askpassURL != nil), environment: env,
                                             timeout: timeout, input: Data(RustDeskServerScript.text.utf8),
                                             outputLimit: 2_000_000)
        return RustDeskServerOutput.interpret(status: result.status, stdout: result.stdout, stderr: result.stderr,
                                              timedOut: result.timedOut, host: valid.host, readAt: now())
    }
}

/// Lecture impossible : la cause et la marche à suivre.
public struct RustDeskServerReadError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Compte SSH absent ou invalide.
        case account
        /// ssh n'a pas pu être lancé.
        case launch
        /// Connexion SSH impossible (réseau, port, nom).
        case unreachable
        /// Authentification refusée (utilisateur, clé, mot de passe).
        case authentication
        /// Empreinte du serveur changée.
        case hostKey
        /// Délai dépassé.
        case timeout
        /// Connexion ouverte, mais le script n'a pas abouti (shell inattendu).
        case script
    }

    public var kind: Kind
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var title: String {
        switch kind {
        case .account: return "Compte SSH du serveur à indiquer"
        case .launch: return "ssh n’a pas pu être lancé"
        case .unreachable: return "Serveur injoignable par SSH"
        case .authentication: return "Connexion SSH refusée"
        case .hostKey: return "Empreinte du serveur changée"
        case .timeout: return "Serveur injoignable par SSH (délai dépassé)"
        case .script: return "Lecture interrompue sur le serveur"
        }
    }

    /// Marche à suivre.
    public var advice: String {
        switch kind {
        case .account:
            return "Dans Réglages › RustDesk, choisissez une connexion SSH du carnet ou saisissez «\u{00A0}utilisateur@hôte\u{00A0}»."
        case .launch:
            return "NetScope utilise /usr/bin/ssh de macOS."
        case .unreachable, .timeout:
            return "Vérifiez que le serveur est allumé et que SSH (port 22 par défaut) est permis depuis ce Mac\u{00A0}: «\u{00A0}Copier la commande\u{00A0}» permet d’essayer dans Terminal."
        case .authentication:
            return "Vérifiez l’utilisateur et la clé, ou enregistrez le mot de passe du compte au Trousseau (connexion SSH du carnet ou Réglages › RustDesk)."
        case .hostKey:
            return "La clé SSH du serveur ne correspond plus à ~/.ssh/known_hosts. Vérifiez qu’il s’agit bien du même serveur, puis retirez l’ancienne empreinte («\u{00A0}ssh-keygen -R hôte\u{00A0}»)."
        case .script:
            return "Le compte doit avoir un shell POSIX (sh, bash). Essayez «\u{00A0}Copier la commande\u{00A0}» dans Terminal pour voir l’erreur."
        }
    }
}
