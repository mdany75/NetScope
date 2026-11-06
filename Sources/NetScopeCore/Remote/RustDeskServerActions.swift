import Darwin
import Foundation

// Note 88 (0.33.1) : actions sur le serveur RustDesk — déconnecter une session relayée (ss -K sur
// l'hôte, hbbr en network_mode: host), redémarrer hbbr, mettre à jour RustDesk (docker compose
// pull puis up -d, avec sauvegarde, étiquette de retour et vérifications) et le système (apt ou
// dnf). Chaque script est fixe ; les seules valeurs insérées (adresse et port d'une session,
// options) sont validées strictement avant. Sortie lue ici, sur des textes fixes en test.

// MARK: - Actions

public enum RustDeskActionKind: String, Codable, CaseIterable, Sendable {
    case disconnect = "deconnecter"
    case restartRelay = "redemarrer-hbbr"
    case updateRustDesk = "maj-rustdesk"
    case updateSystem = "maj-systeme"

    public var label: String {
        switch self {
        case .disconnect: return "Déconnexion d’une session relayée"
        case .restartRelay: return "Redémarrage de hbbr"
        case .updateRustDesk: return "Mise à jour de RustDesk"
        case .updateSystem: return "Mise à jour du système"
        }
    }
}

/// Mises à jour du système : sécurité seulement, ou toutes.
public enum RustDeskUpdateScope: String, Codable, CaseIterable, Sendable {
    case security = "securite"
    case all = "tout"

    public var label: String { self == .security ? "Sécurité seulement" : "Toutes" }
}

/// Mise à jour planifiée : RustDesk, système ou les deux.
public enum RustDeskUpdateTarget: String, Codable, CaseIterable, Sendable {
    case rustdesk, system = "systeme", both = "les-deux"

    public var label: String {
        switch self {
        case .rustdesk: return "RustDesk"
        case .system: return "Système"
        case .both: return "RustDesk et système"
        }
    }

    public var kinds: [RustDeskActionKind] {
        switch self {
        case .rustdesk: return [.updateRustDesk]
        case .system: return [.updateSystem]
        case .both: return [.updateRustDesk, .updateSystem]
        }
    }
}

/// Valeur refusée avant d'entrer dans une commande.
public struct RustDeskActionError: Error, Equatable, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Validation stricte de tout ce qui entre dans une commande.
public enum RustDeskActionValidation {
    /// Adresse IPv4 ou IPv6 (inet_pton), forme canonique de l'entrée seulement (aucun espace,
    /// aucune apostrophe, aucun caractère hors chiffres, lettres a à f, « . » et « : »).
    public static func address(_ text: String) throws -> String {
        let allowed = Set("0123456789abcdefABCDEF.:")
        guard !text.isEmpty, text.count <= 45, text.allSatisfy({ allowed.contains($0) }),
              RustDeskRelaySession.isIPv4(text) || RustDeskRelaySession.isIPv6(text) else {
            throw RustDeskActionError("Adresse de session invalide\u{00A0}: «\u{00A0}\(RemoteShell.sanitizedTitle(text, limit: 60))\u{00A0}».")
        }
        return text
    }

    public static func port(_ value: Int?) throws -> Int? {
        guard let value else { return nil }
        guard (1...65_535).contains(value) else { throw RustDeskActionError("Port de session invalide\u{00A0}: \(value).") }
        return value
    }

    /// ID RustDesk (chiffres seulement) ou vide.
    public static func rustDeskID(_ text: String) throws -> String {
        guard !text.isEmpty else { return "" }
        guard let id = RustDeskID.parse(text), id.allSatisfy(\.isNumber) else {
            throw RustDeskActionError("ID RustDesk invalide\u{00A0}: «\u{00A0}\(RemoteShell.sanitizedTitle(text, limit: 40))\u{00A0}».")
        }
        return id
    }

    /// Nom de conteneur Docker (lettres, chiffres, « _ », « . », « - »), 128 caractères au plus.
    public static func containerName(_ text: String) throws -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard let first = text.first, first.isLetter || first.isNumber, text.count <= 128,
              text.allSatisfy({ allowed.contains($0) }) else {
            throw RustDeskActionError("Nom de conteneur invalide\u{00A0}: «\u{00A0}\(RemoteShell.sanitizedTitle(text, limit: 60))\u{00A0}».")
        }
        return text
    }
}

/// Action demandée, avec tout ce que la confirmation doit dire.
public struct RustDeskServerAction: Equatable, Identifiable, Sendable {
    public var id: String { kind.rawValue + "|" + peerAddress + "|" + String(peerPort ?? 0) }
    public var kind: RustDeskActionKind
    /// Déconnexion : adresse et port validés de la session ; ID et nom du poste (affichés seulement).
    public var peerAddress: String = ""
    public var peerPort: Int?
    public var targetID: String = ""
    public var station: String = ""
    /// Mise à jour du système.
    public var scope: RustDeskUpdateScope = .all
    public var allowReboot = false
    /// Mise à jour planifiée : reportée si une session relayée est en cours.
    public var postponeIfSession = false
    /// Sessions relayées en cours au moment de la confirmation (signalées) ; nil : inconnues
    /// (console de hbbr illisible).
    public var activeSessions: Int? = 0

    /// La première conséquence avertit de sessions coupées (connues ou peut-être).
    public var warnsSessions: Bool { kind != .disconnect && (activeSessions ?? 1) > 0 }

    private init(kind: RustDeskActionKind) {
        self.kind = kind
    }

    /// Déconnecter une session relayée : adresse, port et ID validés ici.
    public static func disconnect(_ session: RustDeskRelaySession, targetID: String = "", station: String = "") throws -> RustDeskServerAction {
        var action = RustDeskServerAction(kind: .disconnect)
        action.peerAddress = try RustDeskActionValidation.address(session.ip)
        // Sans port, le filtre viserait toutes les connexions de cette IP (postes derrière le même
        // NAT) : l'IP seule ne choisit jamais un appareil.
        guard let port = try RustDeskActionValidation.port(session.port) else {
            throw RustDeskActionError("Port de la session inconnu\u{00A0}: déconnexion refusée, elle couperait toutes les sessions venant de \(action.peerAddress) (postes derrière le même routeur).")
        }
        action.peerPort = port
        action.targetID = try RustDeskActionValidation.rustDeskID(targetID)
        action.station = RemoteShell.sanitizedTitle(station, limit: 60)
        return action
    }

    public static func restartRelay(activeSessions: Int?) -> RustDeskServerAction {
        var action = RustDeskServerAction(kind: .restartRelay)
        action.activeSessions = activeSessions.map { max(0, $0) }
        return action
    }

    public static func updateRustDesk(activeSessions: Int?, postponeIfSession: Bool = false) -> RustDeskServerAction {
        var action = RustDeskServerAction(kind: .updateRustDesk)
        action.activeSessions = activeSessions.map { max(0, $0) }
        action.postponeIfSession = postponeIfSession
        return action
    }

    public static func updateSystem(scope: RustDeskUpdateScope, allowReboot: Bool, activeSessions: Int?,
                                    postponeIfSession: Bool = false) -> RustDeskServerAction {
        var action = RustDeskServerAction(kind: .updateSystem)
        action.scope = scope
        action.allowReboot = allowReboot
        action.activeSessions = activeSessions.map { max(0, $0) }
        action.postponeIfSession = postponeIfSession
        return action
    }

    /// « 203.0.113.58:51234 » ou « [2001:db8::5]:51234 ».
    public var peerLabel: String {
        let host = peerAddress.contains(":") ? "[\(peerAddress)]" : peerAddress
        return peerPort.map { "\(host):\($0)" } ?? host
    }

    /// Cible notée dans l'historique.
    public var target: String {
        switch kind {
        case .disconnect:
            let who = !station.isEmpty ? station : (targetID.isEmpty ? "" : RustDeskID.grouped(targetID, separator: " "))
            return who.isEmpty ? peerLabel : "\(peerLabel) (\(who))"
        case .restartRelay: return "hbbr"
        case .updateRustDesk: return "hbbs et hbbr (Docker)"
        case .updateSystem: return scope.label + (allowReboot ? ", redémarrage permis" : "")
        }
    }

    public var title: String {
        switch kind {
        case .disconnect: return "Déconnecter la session relayée de \(peerLabel)\u{00A0}?"
        case .restartRelay: return "Redémarrer hbbr\u{00A0}?"
        case .updateRustDesk: return "Mettre à jour RustDesk Server\u{00A0}?"
        case .updateSystem: return "Mettre à jour le système du serveur\u{00A0}?"
        }
    }

    public var confirmLabel: String {
        switch kind {
        case .disconnect: return "Déconnecter"
        case .restartRelay: return "Redémarrer hbbr"
        case .updateRustDesk: return "Mettre à jour RustDesk"
        case .updateSystem: return "Mettre à jour le système"
        }
    }

    private var sessionsWarning: String? {
        guard let activeSessions else {
            return "Sessions relayées en cours inconnues (console de hbbr illisible)\u{00A0}: elles seront peut-être coupées."
        }
        guard activeSessions > 0 else { return nil }
        return "\(activeSessions) session\(activeSessions > 1 ? "s" : "") relayée\(activeSessions > 1 ? "s" : "") en cours\u{00A0}: elle\(activeSessions > 1 ? "s seront coupées" : " sera coupée")."
    }

    /// Ce qui va se passer, dit avant de confirmer.
    public var consequences: [String] {
        switch kind {
        case .disconnect:
            return ["NetScope ferme par SSH la connexion relayée de \(peerLabel) sur hbbr («\u{00A0}ss -K\u{00A0}», avec sudo), puis vérifie qu’elle a disparu.",
                    "Les autres sessions ne sont pas touchées. Le poste peut se reconnecter aussitôt (aucun blocage).",
                    "Si le noyau refuse de fermer la connexion, NetScope le dit\u{00A0}: redémarrer hbbr coupe alors toutes les sessions (proposé à part)."]
        case .restartRelay:
            return [sessionsWarning ?? "Aucune session relayée en cours.",
                    "Redémarre le conteneur hbbr (ou le service rustdesk-hbbr), puis vérifie qu’il écoute de nouveau sur le port 21117.",
                    "Toutes les sessions relayées sont coupées\u{00A0}; les postes se reconnectent ensuite."]
        case .updateRustDesk:
            var lines = [sessionsWarning ?? "Aucune session relayée en cours."]
            if postponeIfSession { lines.append("Reportée si une session relayée est en cours.") }
            lines += ["Avant\u{00A0}: clé et base sauvegardées sur le serveur (/var/backups), image actuelle étiquetée «\u{00A0}netscope-avant-…\u{00A0}» pour y revenir, compose relu («\u{00A0}docker compose config\u{00A0}»).",
                      "Puis «\u{00A0}docker compose pull\u{00A0}» et «\u{00A0}docker compose up -d\u{00A0}» dans le dossier du compose (rien n’est redémarré si l’image n’a pas changé).",
                      "Après\u{00A0}: conteneurs, version, ports 21115 à 21117 et clé publique (inchangée) vérifiés\u{00A0}; retour à l’image précédente si RustDesk ne repart pas."]
            return lines
        case .updateSystem:
            var lines = [sessionsWarning ?? "Aucune session relayée en cours."]
            if postponeIfSession { lines.append("Reportée si une session relayée est en cours.") }
            lines.append(scope == .security
                         ? "Mises à jour de sécurité seulement (apt\u{00A0}: unattended-upgrade\u{00A0}; dnf\u{00A0}: upgrade --security)."
                         : "Toutes les mises à jour (apt-get upgrade, en gardant les fichiers de configuration actuels\u{00A0}; dnf upgrade).")
            lines.append(allowReboot ? "Redémarrage du serveur permis\u{00A0}: s’il est requis, le serveur redémarre une minute après (toutes les sessions coupées)."
                                     : "Redémarrage du serveur non permis\u{00A0}: s’il est requis, NetScope le signale seulement.")
            return lines
        }
    }

    /// Script complet envoyé sur l'entrée standard (après la ligne du mot de passe sudo).
    public var script: String {
        RustDeskServerActionScript.script(for: self)
    }
}

// MARK: - Scripts

public enum RustDeskServerActionScript {
    /// En-tête : celui des lectures (asroot, dk, NOMS, DATA) et les fonctions du journal d'action.
    static let prelude: String = RustDeskServerDetailScript.prelude
        .replacingOccurrences(of: "# NetScope : lecture seule du serveur RustDesk ; aucune commande ne modifie le serveur.",
                              with: "# NetScope : action sur le serveur RustDesk, confirmée dans NetScope.")
        + "\n" + #"""
    etape() { printf 'ETAPE %s %s\n' "$1" "$2"; }
    val() { printf 'VAL %s=%s\n' "$1" "$2"; }
    fin() { section RESULTAT; echo "$1"; NETSCOPE_MDP=; section FIN; exit 0; }
    dkl() { if [ "$DKDIRECT" = 1 ]; then timeout 900 docker "$@" </dev/null; else asroot timeout 900 docker "$@"; fi; }
    relais() { ss -tn state established '( sport = :21117 )' 2>/dev/null | tail -n +2 | grep -c .; }
    section JOURNAL
    # Après un refus, le prélude a vidé le mot de passe : ce test passe par « sudo -n » (aucun nouvel essai).
    if [ "$(id -u)" != 0 ] && ! asroot true >/dev/null 2>&1; then
      etape echec "sudo refusé : mot de passe sudo absent ou incorrect (Réglages › RustDesk)."; fin echec
    fi
    """#

    /// Port d'écoute de hbbr (sessions relayées).
    public static let relayPort = RustDeskConsoleCommand.relayPort

    public static func script(for action: RustDeskServerAction) -> String {
        switch action.kind {
        case .disconnect: return disconnect(action)
        case .restartRelay: return prelude + "\n" + restartRelay + "\n" + "fin ok\n"
        case .updateRustDesk: return prelude + "\n" + postpone(action) + updateRustDesk
        case .updateSystem: return prelude + "\n" + postpone(action) + updateSystem(action)
        }
    }

    /// Filtre ss d'une session : adresse validée, aussi sous sa forme IPv4 vue en IPv6.
    static func ssFilter(_ action: RustDeskServerAction) -> String {
        func endpoint(_ host: String) -> String {
            let bracketed = host.contains(":") ? "[\(host)]" : host
            return action.peerPort.map { "dst \(bracketed):\($0)" } ?? "dst \(bracketed)"
        }
        var targets = [endpoint(action.peerAddress)]
        if RustDeskRelaySession.isIPv4(action.peerAddress) { targets.append(endpoint("::ffff:" + action.peerAddress)) }
        return "( sport = :\(relayPort) ) and ( " + targets.joined(separator: " or ") + " )"
    }

    static func disconnect(_ action: RustDeskServerAction) -> String {
        // Valeurs déjà validées (adresse inet_pton, port 1 à 65535) : aucun guillemet possible.
        prelude + "\n" + "FILTRE='" + ssFilter(action) + "'\n" + "CIBLE='" + action.peerLabel + "'\n" + #"""
    command -v ss >/dev/null 2>&1 || { etape echec "ss introuvable sur le serveur (paquet iproute2)."; fin echec; }
    compte() { asroot ss -tn state established "$FILTRE" 2>/dev/null | tail -n +2 | grep -c .; }
    n=$(compte)
    val avant "$n"
    if [ "$n" = 0 ]; then etape info "Aucune connexion relayée de $CIBLE : la session est déjà terminée."; fin ok; fi
    asroot ss -K -tn state established "$FILTRE" >/dev/null 2>&1
    sleep 1
    n2=$(compte)
    val apres "$n2"
    if [ "$n2" = 0 ]; then
      etape ok "Connexion relayée de $CIBLE fermée ($n connexion(s)). Le poste peut se reconnecter."
      fin ok
    fi
    etape echec "La connexion de $CIBLE est toujours là : le noyau refuse sans doute « ss -K » (CONFIG_INET_DIAG_DESTROY). Redémarrer hbbr coupe toutes les sessions."
    fin echec
    """#
    }

    /// Mise à jour planifiée : reportée si une session relayée est en cours.
    static func postpone(_ action: RustDeskServerAction) -> String {
        guard action.postponeIfSession else { return "" }
        return #"""
        n=$(relais)
        if [ "${n:-0}" -gt 0 ]; then val sessions "$n"; etape info "$n connexion(s) relayée(s) en cours : mise à jour reportée."; fin reporte; fi

        """#
    }

    static let restartRelay = #"""
    n=$(relais)
    val sessions "${n:-0}"
    R=$(printf '%s\n' $NOMS | grep -i hbbr | head -n 1)
    # Image tout-en-un (un seul conteneur, sans « hbbr » dans le nom) : ce conteneur-là.
    if [ -z "$R" ] && [ "$(printf '%s\n' $NOMS | grep -c .)" = 1 ]; then R=$(printf '%s\n' $NOMS | head -n 1); fi
    if [ -n "$R" ]; then
      dk restart "$R" >/dev/null 2>&1 || { etape echec "docker restart $R a échoué."; fin echec; }
      etape ok "Conteneur $R redémarré."
    elif command -v systemctl >/dev/null 2>&1 && systemctl cat rustdesk-hbbr >/dev/null 2>&1; then
      asroot systemctl restart rustdesk-hbbr || { etape echec "systemctl restart rustdesk-hbbr a échoué."; fin echec; }
      etape ok "Service rustdesk-hbbr redémarré."
    else
      etape echec "hbbr introuvable (ni conteneur, ni service rustdesk-hbbr)."; fin echec
    fi
    i=0
    while [ $i -lt 15 ]; do
      if ss -ltn '( sport = :21117 )' 2>/dev/null | tail -n +2 | grep -q .; then break; fi
      sleep 2; i=$((i+1))
    done
    if ss -ltn '( sport = :21117 )' 2>/dev/null | tail -n +2 | grep -q .; then etape ok "hbbr écoute de nouveau sur le port 21117."
    else etape echec "hbbr n’écoute pas sur le port 21117 après 30 s."; fin echec; fi
    """#

    static let updateRustDesk = #"""
    command -v docker >/dev/null 2>&1 || { etape echec "Docker absent : RustDesk n’est pas en conteneur ici ; mise à jour par le gestionnaire de paquets (rustdesk-server-hbbs, -hbbr) à faire à la main."; fin echec; }
    S=$(printf '%s\n' $NOMS | grep -i hbbs | head -n 1)
    R=$(printf '%s\n' $NOMS | grep -i hbbr | head -n 1)
    # Image tout-en-un (un seul conteneur, sans « hbbs » ni « hbbr » dans le nom) : ce conteneur-là.
    if [ -z "$S$R" ] && [ "$(printf '%s\n' $NOMS | grep -c .)" = 1 ]; then S=$(printf '%s\n' $NOMS | head -n 1); fi
    [ -n "$S" ] || { etape echec "Conteneur hbbs introuvable."; fin echec; }
    [ -n "$R" ] || R=$S
    lab() { dk inspect --format "{{index .Config.Labels \"$1\"}}" "$S" 2>/dev/null; }
    DIR=$(lab com.docker.compose.project.working_dir)
    PROJ=$(lab com.docker.compose.project)
    CFG=$(lab com.docker.compose.project.config_files)
    [ -n "$DIR" ] || { etape echec "hbbs n’a pas été lancé par docker compose : mise à jour automatique non prise en charge."; fin echec; }
    if dkl compose version >/dev/null 2>&1; then DCV=2
    elif command -v docker-compose >/dev/null 2>&1; then DCV=1
    else etape echec "Ni « docker compose » ni « docker-compose » sur le serveur."; fin echec; fi
    # Même projet et mêmes fichiers qu’au lancement (étiquettes du conteneur), sans « cd » : le
    # dossier peut être fermé au compte SSH ; docker les lit en root. Valeurs toujours entre guillemets.
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
    val projet "$PROJ"
    n=$(relais)
    val sessions "${n:-0}"
    if [ "${n:-0}" -gt 0 ]; then etape attention "$n connexion(s) relayée(s) en cours : coupées si l’image change."; fi
    # Avant : compose relu.
    if dc config -q >/dev/null 2>&1; then etape ok "Compose relu sans erreur ($DIR)."
    else etape echec "Le compose de $DIR ne se lit pas (docker compose config) : rien n’est changé."; fin echec; fi
    # Avant : clé et base sauvegardées sur le serveur.
    STAMP=$(date +%Y%m%d-%H%M%S)
    [ -n "$DATA" ] || { etape echec "Dossier des données (clé, base) introuvable : rien n’est changé."; fin echec; }
    F=
    for f in id_ed25519 id_ed25519.pub db_v2.sqlite3 db_v2.sqlite3-wal db_v2.sqlite3-shm; do
      if asroot test -e "$DATA/$f" 2>/dev/null; then F="$F $f"; fi
    done
    B="/var/backups/netscope-rustdesk-$STAMP.tar.gz"
    # Archive créée en 600 (umask 077, puis chmod vérifié) : elle contient la clé privée du serveur.
    if asroot mkdir -p /var/backups && asroot sh -c 'umask 077; exec tar -C "$1" -czf "$2" $3' sh "$DATA" "$B" "$F" 2>/dev/null \
       && asroot chmod 600 "$B"; then etape ok "Clé et base sauvegardées (lisibles par root seulement) : $B"; val sauvegarde "$B"
    else etape echec "Sauvegarde de la clé et de la base impossible : rien n’est changé."; fin echec; fi
    CLE1=$(asroot head -c 200 "$DATA/id_ed25519.pub" 2>/dev/null)
    V1=$(dk exec "$S" hbbs --version 2>/dev/null | head -n 1)
    val version_avant "$V1"
    # Avant : image actuelle étiquetée pour y revenir.
    IMG=$(dk inspect --format '{{.Config.Image}}' "$S" 2>/dev/null)
    IID=$(dk inspect --format '{{.Image}}' "$S" 2>/dev/null)
    REPO=$(printf '%s' "$IMG" | sed 's/:[^:/]*$//')
    RETOUR="$REPO:netscope-avant-$STAMP"
    if dk tag "$IID" "$RETOUR" >/dev/null 2>&1; then etape ok "Image actuelle étiquetée $RETOUR."; val image_retour "$RETOUR"
    else etape echec "Étiquette de retour impossible : rien n’est changé."; fin echec; fi
    # hbbr sur une autre image : étiquetée et vérifiée aussi.
    IMGR=$(dk inspect --format '{{.Config.Image}}' "$R" 2>/dev/null)
    IIDR=$(dk inspect --format '{{.Image}}' "$R" 2>/dev/null)
    RETOURR=
    if [ -n "$IMGR" ] && [ "$IMGR" != "$IMG" ]; then
      RETOURR="$(printf '%s' "$IMGR" | sed 's/:[^:/]*$//'):netscope-avant-$STAMP"
      if dk tag "$IIDR" "$RETOURR" >/dev/null 2>&1; then etape ok "Image de hbbr étiquetée $RETOURR."; val image_retour_hbbr "$RETOURR"
      else etape echec "Étiquette de retour de hbbr impossible : rien n’est changé."; fin echec; fi
    fi
    # Mise à jour.
    if dc pull >/dev/null 2>&1; then etape ok "docker compose pull terminé."
    else etape echec "docker compose pull a échoué (réseau, registre) : rien n’est changé."; fin echec; fi
    NID=$(dk image inspect --format '{{.Id}}' "$IMG" 2>/dev/null)
    NIDR=$IIDR
    if [ -n "$RETOURR" ]; then NIDR=$(dk image inspect --format '{{.Id}}' "$IMGR" 2>/dev/null); fi
    if [ "$NID" = "$IID" ] && [ "$NIDR" = "$IIDR" ]; then etape info "Déjà à jour : aucune nouvelle image, rien n’est redémarré."; val version_apres "$V1"; fin ok; fi
    if dc up -d >/dev/null 2>&1; then etape ok "docker compose up -d terminé."; else etape attention "docker compose up -d a signalé une erreur."; fi
    verifier() {
      i=0
      while [ $i -lt 15 ]; do
        ok=1
        for c in $S $R; do [ "$(dk inspect --format '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || ok=0; done
        for p in 21115 21116 21117; do ss -ltn "( sport = :$p )" 2>/dev/null | tail -n +2 | grep -q . || ok=0; done
        [ $ok = 1 ] && return 0
        sleep 2; i=$((i+1))
      done
      return 1
    }
    if verifier; then
      etape ok "hbbs et hbbr tournent, ports 21115 à 21117 à l’écoute."
      V2=$(dk exec "$S" hbbs --version 2>/dev/null | head -n 1)
      val version_apres "$V2"
      CLE2=$(asroot head -c 200 "$DATA/id_ed25519.pub" 2>/dev/null)
      if [ -n "$CLE1" ] && [ "$CLE1" = "$CLE2" ]; then etape ok "Clé publique inchangée."
      else etape attention "Clé publique différente ou illisible après la mise à jour : vérifier les postes (sauvegarde $B)."; fi
      fin ok
    fi
    etape echec "RustDesk ne repart pas après la mise à jour : retour à l’image précédente."
    REMIS=1
    dk tag "$RETOUR" "$IMG" >/dev/null 2>&1 || REMIS=0
    if [ -n "$RETOURR" ]; then dk tag "$RETOURR" "$IMGR" >/dev/null 2>&1 || REMIS=0; fi
    if [ $REMIS = 1 ] && dc up -d >/dev/null 2>&1 && verifier; then
      etape ok "Image précédente remise ($RETOUR) : RustDesk tourne de nouveau."
      val retour ok
    else
      etape echec "Retour à l’image précédente impossible : intervention manuelle requise (sauvegarde $B, image $RETOUR)."
      val retour echec
    fi
    fin echec
    """#

    static func updateSystem(_ action: RustDeskServerAction) -> String {
        "SECU=" + (action.scope == .security ? "1" : "0") + "\nREDEM=" + (action.allowReboot ? "1" : "0") + "\n" + #"""
    if command -v apt-get >/dev/null 2>&1; then
      val gestionnaire apt
      if asroot timeout 600 apt-get update -q >/dev/null 2>&1; then etape ok "Listes de paquets rafraîchies (apt-get update)."
      else etape echec "apt-get update a échoué."; fin echec; fi
      # Compte « avant » pris sur les listes rafraîchies.
      A1=$(apt list --upgradable 2>/dev/null | grep -vc '^Listing')
      if [ "$SECU" = 1 ]; then
        command -v unattended-upgrade >/dev/null 2>&1 || { etape echec "Sécurité seulement : unattended-upgrades n’est pas installé sur le serveur."; fin echec; }
        if asroot env DEBIAN_FRONTEND=noninteractive timeout 3600 unattended-upgrade >/dev/null 2>&1; then etape ok "Mises à jour de sécurité installées (unattended-upgrade)."
        else etape echec "unattended-upgrade a échoué."; fin echec; fi
      else
        if asroot env DEBIAN_FRONTEND=noninteractive timeout 3600 apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade >/dev/null 2>&1; then etape ok "Mises à jour installées (apt-get upgrade)."
        else etape echec "apt-get upgrade a échoué."; fin echec; fi
      fi
      A2=$(apt list --upgradable 2>/dev/null | grep -vc '^Listing')
      val restantes "$A2"
      etape info "Paquets à mettre à jour : ${A1:-?} avant, ${A2:-?} après."
    elif command -v dnf >/dev/null 2>&1; then
      val gestionnaire dnf
      if [ "$SECU" = 1 ]; then O=--security; else O=; fi
      if asroot timeout 3600 dnf -y -q upgrade $O >/dev/null 2>&1; then etape ok "Mises à jour installées (dnf upgrade $O)."
      else etape echec "dnf upgrade a échoué."; fin echec; fi
    else
      etape echec "Gestionnaire de paquets inconnu (ni apt ni dnf)."; fin echec
    fi
    REQ=non
    if [ -e /var/run/reboot-required ]; then REQ=oui
    elif command -v needs-restarting >/dev/null 2>&1; then timeout 30 needs-restarting -r >/dev/null 2>&1; [ $? = 1 ] && REQ=oui; fi
    val redemarrage "$REQ"
    if [ "$REQ" = oui ] && [ "$REDEM" = 1 ]; then
      if asroot shutdown -r +1 "NetScope : redémarrage après les mises à jour" >/dev/null 2>&1; then etape ok "Redémarrage du serveur dans une minute."
      else etape echec "Redémarrage demandé mais refusé (shutdown -r)."; fin echec; fi
    elif [ "$REQ" = oui ]; then
      etape attention "Redémarrage requis, non permis : à faire plus tard."
    fi
    fin ok
    """#
    }

    /// Commandes qui modifient le serveur, permises par action (vérifié par les tests).
    public static let modifyingWords: [RustDeskActionKind: [String]] = [
        .disconnect: ["ss -K"],
        .restartRelay: ["dk restart", "systemctl restart"],
        .updateRustDesk: ["mkdir -p /var/backups", "tar -C", "chmod 600", "dk tag", "dc pull", "dc up -d"],
        .updateSystem: ["apt-get update", "unattended-upgrade", "apt-get -y", "dnf -y", "shutdown -r"],
    ]
}

// MARK: - Résultat

public enum RustDeskActionOutcome: String, Codable, CaseIterable, Sendable {
    case ok
    case failed = "echec"
    /// Mise à jour planifiée reportée (session relayée en cours).
    case postponed = "reporte"
    /// Fenêtre passée sans pouvoir la faire (sessions en cours tout du long).
    case skipped = "abandonne"
    /// Échéance manquée (Mac éteint, agent arrêté).
    case missed = "manque"
    /// Démonstration : rien n'est envoyé.
    case simulated = "simule"

    public var label: String {
        switch self {
        case .ok: return "Réussie"
        case .failed: return "Échec"
        case .postponed: return "Reportée"
        case .skipped: return "Abandonnée"
        case .missed: return "Manquée"
        case .simulated: return "Simulée"
        }
    }

    /// Fin d'une échéance planifiée (plus de nouvel essai pour elle).
    public var closesSlot: Bool { self != .postponed }
}

public struct RustDeskActionStep: Codable, Equatable, Sendable {
    /// « ok », « echec », « info », « attention ».
    public var level: String
    public var text: String

    public init(level: String, text: String) {
        self.level = level
        self.text = text
    }
}

/// Sortie d'un script d'action.
public struct RustDeskActionOutput: Equatable, Sendable {
    public var outcome: RustDeskActionOutcome
    public var steps: [RustDeskActionStep]
    public var values: [String: String]
    /// La sortie s'arrête avant la fin (connexion coupée, délai dépassé).
    public var complete: Bool

    public static func parse(_ text: String) -> RustDeskActionOutput {
        let parts = RustDeskServerOutput.sections(text)
        var steps: [RustDeskActionStep] = []
        var values: [String: String] = [:]
        for line in parts["JOURNAL"]?.lines ?? [] {
            if line.hasPrefix("ETAPE ") {
                let rest = line.dropFirst(6)
                let level = rest.prefix { $0 != " " }
                let text = rest.dropFirst(level.count).trimmingCharacters(in: .whitespaces)
                guard ["ok", "echec", "info", "attention"].contains(String(level)) else { continue }
                steps.append(RustDeskActionStep(level: String(level), text: RemoteShell.sanitizedTitle(text, limit: 300)))
            } else if line.hasPrefix("VAL "), let equal = line.firstIndex(of: "=") {
                let key = String(line[line.index(line.startIndex, offsetBy: 4)..<equal])
                values[key] = RemoteShell.sanitizedTitle(String(line[line.index(after: equal)...]), limit: 200)
            }
        }
        let complete = parts["FIN"] != nil
        let word = parts["RESULTAT"]?.lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var outcome: RustDeskActionOutcome
        switch word {
        case "ok": outcome = .ok
        case "reporte": outcome = .postponed
        default: outcome = .failed
        }
        if !complete {
            outcome = .failed
            steps.append(RustDeskActionStep(level: "echec", text: "Sortie interrompue avant la fin (connexion coupée ou délai dépassé)\u{00A0}: vérifier le serveur."))
        }
        // Une étape en échec l'emporte sur un « ok » final (sauf retour réussi, déjà en échec).
        if outcome == .ok, steps.contains(where: { $0.level == "echec" }) { outcome = .failed }
        return RustDeskActionOutput(outcome: outcome, steps: steps, values: values, complete: complete)
    }

    /// Résumé d'une ligne pour l'historique.
    public func summary(for kind: RustDeskActionKind) -> String {
        switch outcome {
        case .postponed: return "Reportée\u{00A0}: session relayée en cours."
        case .failed:
            return steps.last(where: { $0.level == "echec" })?.text ?? "Échec."
        default:
            if kind == .updateRustDesk, let before = values["version_avant"], let after = values["version_apres"],
               let a = RustDeskVersionCheck.versionNumber(before), let b = RustDeskVersionCheck.versionNumber(after) {
                return a == b ? "RustDesk Server \(b), déjà à jour ou même version." : "RustDesk Server \(a) → \(b)."
            }
            return steps.last(where: { $0.level == "ok" || $0.level == "info" })?.text ?? "Terminée."
        }
    }
}

// MARK: - Historique

/// Action notée dans l'historique (fichier du suivi, synchronisé).
public struct RustDeskActionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: RustDeskActionKind
    public var target: String
    public var outcome: RustDeskActionOutcome
    public var summary: String
    public var steps: [RustDeskActionStep]
    /// « MacBook Pro de Dany » ou « MacBook Pro de Dany (agent, planifiée) ».
    public var origin: String
    /// Échéance planifiée traitée (nil : action à la main).
    public var slot: Date?

    public init(id: UUID = UUID(), date: Date, kind: RustDeskActionKind, target: String, outcome: RustDeskActionOutcome,
                summary: String, steps: [RustDeskActionStep] = [], origin: String, slot: Date? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.target = target
        self.outcome = outcome
        self.summary = summary
        self.steps = Array(steps.prefix(40))
        self.origin = origin
        self.slot = slot
    }

    public static let limit = 300

    /// Union par identifiant, la plus récente en premier, 300 au plus.
    public static func union(_ a: [RustDeskActionRecord], _ b: [RustDeskActionRecord]) -> [RustDeskActionRecord] {
        var byID: [UUID: RustDeskActionRecord] = [:]
        for record in a + b where byID[record.id] == nil { byID[record.id] = record }
        return Array(byID.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }.prefix(limit))
    }
}

// MARK: - Mise à jour planifiée

/// Fenêtre de mise à jour planifiée, faite par l'agent d'un seul Mac.
public struct RustDeskUpdateSchedule: Codable, Equatable, Sendable {
    public var enabled = false
    /// 1 = dimanche … 7 = samedi (Calendar).
    public var weekday = 1
    public var hour = 3
    public var minute = 0
    public var target: RustDeskUpdateTarget = .both
    public var scope: RustDeskUpdateScope = .security
    public var allowReboot = false
    public var postponeIfSession = true
    /// Mac qui l'exécute (identifiant matériel) et son nom ; un seul.
    public var runnerID = ""
    public var runnerName = ""
    /// Dernier changement des réglages : une échéance antérieure n'est ni faite ni notée manquée.
    public var changedAt: Date?

    /// Essais permis après l'heure prévue (report si session), puis abandon jusqu'à la semaine suivante.
    public static let window: TimeInterval = 3 * 3_600
    /// Nouvel essai après un report.
    public static let retryDelay: TimeInterval = 15 * 60
    /// Une échéance manquée de plus d'une semaine n'est plus notée.
    public static let missedLimit: TimeInterval = 7 * 86_400

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, weekday, hour, minute, target, scope, allowReboot, postponeIfSession, runnerID, runnerName, changedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
        weekday = min(max(((try? c.decodeIfPresent(Int.self, forKey: .weekday)) ?? nil) ?? 1, 1), 7)
        hour = min(max(((try? c.decodeIfPresent(Int.self, forKey: .hour)) ?? nil) ?? 3, 0), 23)
        minute = min(max(((try? c.decodeIfPresent(Int.self, forKey: .minute)) ?? nil) ?? 0, 0), 59)
        target = ((try? c.decodeIfPresent(RustDeskUpdateTarget.self, forKey: .target)) ?? nil) ?? .both
        scope = ((try? c.decodeIfPresent(RustDeskUpdateScope.self, forKey: .scope)) ?? nil) ?? .security
        allowReboot = ((try? c.decodeIfPresent(Bool.self, forKey: .allowReboot)) ?? nil) ?? false
        postponeIfSession = ((try? c.decodeIfPresent(Bool.self, forKey: .postponeIfSession)) ?? nil) ?? true
        runnerID = ((try? c.decodeIfPresent(String.self, forKey: .runnerID)) ?? nil) ?? ""
        runnerName = ((try? c.decodeIfPresent(String.self, forKey: .runnerName)) ?? nil) ?? ""
        changedAt = (try? c.decodeIfPresent(Date.self, forKey: .changedAt)) ?? nil
    }

    /// Dernière échéance au plus tard à `now`.
    public func lastSlot(atOrBefore now: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.nextDate(after: now.addingTimeInterval(1), matching: components, matchingPolicy: .nextTime, direction: .backward)
    }

    /// Prochaine échéance après `now`.
    public func nextSlot(after now: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    /// « dimanche à 3 h », « mardi à 22 h 30 ».
    public func label(calendar: Calendar) -> String {
        let names = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
        let time = minute == 0 ? "\(hour)\u{00A0}h" : "\(hour)\u{00A0}h\u{00A0}" + String(format: "%02d", minute)
        return "\(names[weekday - 1]) à \(time)"
    }

    public enum Decision: Equatable, Sendable {
        case idle
        /// Essai pour l'échéance (`last` : dernier essai permis dans la fenêtre).
        case run(slot: Date, last: Bool)
        /// Fenêtre passée avec seulement des reports : abandon pour cette semaine.
        case expired(slot: Date)
        /// Échéance passée sans aucun essai (Mac éteint, agent arrêté).
        case missed(slot: Date)
    }

    /// Règle de l'agent : rien si la planification est coupée ou confiée à un autre Mac ; sinon un
    /// essai par échéance, repris toutes les 15 min après un report, jusqu'à la fin de la fenêtre.
    public static func decide(_ schedule: RustDeskUpdateSchedule, now: Date, calendar: Calendar,
                              records: [RustDeskActionRecord], machineID: String) -> Decision {
        guard schedule.enabled, !schedule.runnerID.isEmpty, schedule.runnerID == machineID,
              let slot = schedule.lastSlot(atOrBefore: now, calendar: calendar) else { return .idle }
        if let changed = schedule.changedAt, slot < changed { return .idle }
        // Chaque type d'action a sa fin : « RustDesk réussie, système reporté » reprend le système.
        let open = openKinds(schedule, slot: slot, records: records)
        if open.isEmpty { return .idle }
        let mine = records.filter { $0.slot == slot && open.contains($0.kind) }
        let end = slot.addingTimeInterval(window)
        if let last = mine.map(\.date).max() {
            if now >= end { return .expired(slot: slot) }
            if now < last.addingTimeInterval(retryDelay) { return .idle }
            return .run(slot: slot, last: now.addingTimeInterval(retryDelay) >= end)
        }
        if now >= end {
            return now.timeIntervalSince(slot) < missedLimit ? .missed(slot: slot) : .idle
        }
        return .run(slot: slot, last: now.addingTimeInterval(retryDelay) >= end)
    }

    /// Types d'action de l'échéance encore ouverts (sans résultat qui la ferme), dans l'ordre.
    public static func openKinds(_ schedule: RustDeskUpdateSchedule, slot: Date, records: [RustDeskActionRecord]) -> [RustDeskActionKind] {
        schedule.target.kinds.filter { kind in
            !records.contains { $0.slot == slot && $0.kind == kind && $0.outcome.closesSlot }
        }
    }

    /// Réglages changés : `changedAt` n'avance que si l'échéance elle-même change (activation,
    /// jour, heure, minute, cible, Mac) ; cocher une option ne fait pas oublier une échéance reportée.
    public func changed(from old: RustDeskUpdateSchedule, now: Date) -> RustDeskUpdateSchedule {
        var updated = self
        let timing = enabled != old.enabled || weekday != old.weekday || hour != old.hour || minute != old.minute
            || target != old.target || runnerID != old.runnerID
        updated.changedAt = timing ? now : old.changedAt
        return updated
    }

    /// Actions d'une échéance, dans l'ordre (RustDesk d'abord, puis le système).
    public func actions(activeSessions: Int? = 0) -> [RustDeskServerAction] {
        target.kinds.map { kind in
            kind == .updateRustDesk
                ? .updateRustDesk(activeSessions: activeSessions, postponeIfSession: postponeIfSession)
                : .updateSystem(scope: scope, allowReboot: allowReboot, activeSessions: activeSessions, postponeIfSession: postponeIfSession)
        }
    }

    /// Identifiant matériel de ce Mac (gethostuuid) ; vide s'il est illisible.
    public static func thisMachineID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 2, tv_nsec: 0)
        guard gethostuuid(&bytes, &wait) == 0 else { return "" }
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress).uuidString }
    }
}

// MARK: - Comptes et secrets (partagés par l'app et l'agent)

public enum RustDeskServerCredentials {
    /// Service du Trousseau de RustDesk (mot de passe saisi et mot de passe sudo).
    public static let rustDeskService = "com.danymenard.netscope.rustdesk"
    /// Service du Trousseau des connexions du carnet (Accès distant).
    public static let connectionService = "com.danymenard.netscope.acces"
    public static let manualPasswordPrefix = "tableau-serveur-ssh:"
    public static let sudoPrefix = "tableau-serveur-sudo:"

    /// Compte du serveur : connexion SSH du carnet, sinon compte saisi.
    public static func account(_ settings: RustDeskDashboardSettings, connections: [RemoteConnection]) -> RustDeskServerAccount? {
        if let id = settings.connectionID {
            return connections.first { $0.id == id && $0.proto == .ssh }.flatMap(RustDeskServerAccount.init(connection:))
        }
        let text = settings.manualAccount.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : try? RustDeskServerAccount.parse(text)
    }

    /// Nom au Trousseau du mot de passe SSH : (service, compte).
    public static func secretKey(_ settings: RustDeskDashboardSettings) -> (service: String, account: String)? {
        if let id = settings.connectionID { return (connectionService, id.uuidString) }
        let text = settings.manualAccount.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let account = try? RustDeskServerAccount.parse(text) else { return nil }
        return (rustDeskService, manualPasswordPrefix + account.label.lowercased())
    }

    /// Nom au Trousseau du mot de passe sudo (service RustDesk).
    public static func sudoKey(_ settings: RustDeskDashboardSettings) -> String? {
        settings.accountKey.map { sudoPrefix + $0 }
    }

    /// Mot de passe sudo : celui enregistré, sinon celui du compte SSH s'il s'authentifie par mot
    /// de passe (aucune clé : jamais une phrase de passe de clé envoyée à sudo).
    public static func sudoPassword(stored: String?, sshSecret: String?, account: RustDeskServerAccount) -> String? {
        if let stored, !stored.isEmpty { return stored }
        return account.keyPath.trimmingCharacters(in: .whitespaces).isEmpty ? sshSecret : nil
    }
}

extension RustDeskServerSSH {
    /// Commande distante d'une action (mot de passe sudo en première ligne de l'entrée).
    public static var actionRemoteCommand: String { RustDeskServerDetailScript.remoteCommand }

    /// Commande complète à coller dans Terminal : première ligne vide (aucun mot de passe : sudo -n
    /// ou compte root), puis le script de l'action. Jamais de secret.
    public static func copyableActionCommand(_ account: RustDeskServerAccount, action: RustDeskServerAction) -> String {
        var words = ["ssh", "-T"]
        if !account.jump.isEmpty { words += ["-J", account.jump] }
        if !account.keyPath.isEmpty { words += ["-i", account.keyPath] }
        if account.port != 22 { words += ["-p", String(account.port)] }
        words += ["--", account.destination]
        return RemoteShell.command(words) + " " + RemoteShell.quote(actionRemoteCommand) + " <<'NETSCOPE'\n\n"
            + action.script + "\nNETSCOPE\n"
    }

    /// Délai d'une action (mise à jour du système : jusqu'à une heure et demie).
    public static func actionTimeout(_ kind: RustDeskActionKind) -> TimeInterval {
        switch kind {
        case .disconnect: return 60
        case .restartRelay: return 120
        case .updateRustDesk: return 1_800
        case .updateSystem: return 5_400
        }
    }

    /// Exécute une action confirmée : connexion ssh, mot de passe sudo en première ligne, script fixe.
    public static func runAction(_ account: RustDeskServerAccount, secret: String?, sudoPassword: String?,
                                 action: RustDeskServerAction) async -> Result<RustDeskActionOutput, RustDeskServerReadError> {
        let result = await runDetail(account, secret: secret, sudoPassword: sudoPassword, script: action.script,
                                     timeout: actionTimeout(action.kind), outputLimit: 1_000_000)
        return result.map { RustDeskActionOutput.parse($0) }
    }
}

// MARK: - Alerte

extension AlertEvent {
    /// Mise à jour planifiée du serveur RustDesk en échec, abandonnée ou manquée (alerte de l'agent).
    public static func rustDeskScheduledUpdate(_ record: RustDeskActionRecord) -> AlertEvent? {
        guard [.failed, .skipped, .missed].contains(record.outcome) else { return nil }
        let word = record.outcome == .failed ? "échec" : record.outcome == .skipped ? "abandonnée" : "manquée"
        return AlertEvent(kind: .serviceIncident, severity: record.outcome == .failed ? .critical : .warning,
                          title: "Serveur RustDesk\u{00A0}: mise à jour planifiée \(word)", message: record.summary,
                          subject: "rustdesk-maj|\(record.kind.rawValue)|\(Int(record.slot?.timeIntervalSince1970 ?? 0))",
                          occurredAt: record.date,
                          details: [AlertDetail("Action", record.kind.label), AlertDetail("Cible", record.target), AlertDetail("Origine", record.origin)])
    }
}
