import Foundation

// Installation des outils externes (note 17) : iperf3, telnet, Speedtest d'Ookla.
//
// Règles : la formule Homebrew vient TOUJOURS de cette liste blanche, jamais d'une saisie ; la
// commande est fixe, affichée dans NetScope avant le clic puis dans Terminal, qui attend la touche
// Entrée avant de lancer quoi que ce soit (Ctrl-C ou fermer la fenêtre annule). Aucune élévation
// de droits : Homebrew s'installe et installe ses formules sans sudo caché.

/// Outil externe que NetScope sait faire installer (liste blanche).
public enum InstallableTool: String, CaseIterable, Codable, Sendable {
    case iperf3
    case telnet
    case ooklaSpeedtest

    /// Nom affiché (« iperf3 », « telnet », « Speedtest d’Ookla »).
    public var displayName: String {
        switch self {
        case .iperf3: return "iperf3"
        case .telnet: return "telnet"
        case .ooklaSpeedtest: return "Speedtest d’Ookla (CLI)"
        }
    }

    /// Formule Homebrew, fixe.
    public var formula: String {
        switch self {
        case .iperf3: return "iperf3"
        case .telnet: return "telnet"
        // Dépôt officiel d'Ookla (« tap ») : Homebrew l'ajoute de lui-même.
        case .ooklaSpeedtest: return "teamookla/speedtest/speedtest"
        }
    }

    /// Emplacements où l'outil est cherché (Homebrew Apple Silicon, puis Intel, puis système).
    public var candidatePaths: [String] {
        switch self {
        case .iperf3: return IperfLocator.candidatePaths
        case .telnet: return RemoteLauncher.telnetPaths
        case .ooklaSpeedtest: return OoklaLocator.candidatePaths
        }
    }

    /// À quoi sert l'outil, en une phrase.
    public var purpose: String {
        switch self {
        case .iperf3: return "mesure le débit entre ce Mac et un autre appareil du réseau"
        case .telnet: return "client Telnet pour les switchs et anciens équipements"
        case .ooklaSpeedtest: return "test de débit par les serveurs Speedtest.net, avec l’outil officiel d’Ookla"
        }
    }

    /// Page officielle de l'outil (téléchargement sans Homebrew).
    public var officialURL: URL {
        switch self {
        case .iperf3: return URL(string: "https://software.es.net/iperf/obtaining.html")!
        case .telnet: return URL(string: "https://formulae.brew.sh/formula/telnet")!
        case .ooklaSpeedtest: return URL(string: "https://www.speedtest.net/apps/cli")!
        }
    }

    /// Libellé du lien vers la page officielle.
    public var officialLabel: String {
        switch self {
        case .iperf3: return "Page officielle d’iperf3 (ESnet)"
        case .telnet: return "Fiche Homebrew de telnet"
        case .ooklaSpeedtest: return "Page officielle du CLI d’Ookla"
        }
    }

    /// Commande montrée à l'utilisateur (« brew install iperf3 »).
    public var displayCommand: String { "brew install \(formula)" }
}

/// Homebrew : présence et commandes.
public enum Homebrew {
    public static let candidatePaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    /// Site officiel : la commande d'installation y est publiée.
    public static let siteURL = URL(string: "https://brew.sh/fr/")!
    /// Commande officielle d'installation publiée sur brew.sh.
    public static let officialInstallCommand =
        "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    public static func find(paths: [String] = candidatePaths, fileManager: FileManager = .default) -> String? {
        paths.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

/// État d'un outil externe.
public enum ToolPresence: Equatable, Sendable {
    case installed(path: String)
    /// Absent, Homebrew présent (chemin de brew).
    case missingWithHomebrew(brew: String)
    /// Absent, Homebrew absent.
    case missingWithoutHomebrew

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    public var path: String? {
        if case .installed(let path) = self { return path }
        return nil
    }
}

/// Détection et scripts d'installation, sans accès réseau (testables).
public enum ToolInstaller {
    /// Chemin de l'outil, s'il est installé.
    public static func find(_ tool: InstallableTool, fileManager: FileManager = .default) -> String? {
        tool.candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// État de l'outil. `toolPaths` et `brewPaths` : emplacements (remplaçables pour les tests).
    public static func presence(_ tool: InstallableTool, toolPaths: [String]? = nil,
                                brewPaths: [String] = Homebrew.candidatePaths,
                                fileManager: FileManager = .default) -> ToolPresence {
        let paths = toolPaths ?? tool.candidatePaths
        // /usr/bin/telnet n'existe plus depuis macOS 10.13, mais on l'accepte s'il est là.
        if let path = paths.first(where: { fileManager.isExecutableFile(atPath: $0) }) { return .installed(path: path) }
        if let brew = Homebrew.find(paths: brewPaths, fileManager: fileManager) { return .missingWithHomebrew(brew: brew) }
        return .missingWithoutHomebrew
    }

    /// Commande réellement lancée (chemin complet de brew, formule de la liste blanche).
    public static func installCommand(_ tool: InstallableTool, brewPath: String) -> String {
        RemoteShell.command([brewPath, "install", tool.formula])
    }

    /// Script .command ouvert par Terminal pour installer `tool` : il s'efface, affiche la commande
    /// et attend Entrée avant de la lancer (Ctrl-C ou fermer la fenêtre annule).
    public static func installScript(_ tool: InstallableTool, brewPath: String) -> String {
        confirmScript(title: "NetScope › installation de \(tool.displayName)",
                      explanation: "Homebrew va installer \(tool.displayName) (\(tool.purpose)).",
                      command: installCommand(tool, brewPath: brewPath),
                      after: "Terminé. Revenez à NetScope : \(tool.displayName) est détecté de lui-même.")
    }

    /// Script .command pour installer Homebrew par sa commande officielle (brew.sh), après Entrée.
    public static func homebrewScript() -> String {
        confirmScript(title: "NetScope › installation de Homebrew",
                      explanation: "Commande officielle publiée sur brew.sh. Homebrew demandera lui-même votre mot de passe de session s’il en a besoin.",
                      command: Homebrew.officialInstallCommand,
                      after: "Terminé. Suivez les « Next steps » affichés par Homebrew, puis revenez à NetScope.")
    }

    static func confirmScript(title: String, explanation: String, command: String, after: String) -> String {
        """
        #!/bin/zsh
        rm -f -- "$0"
        printf '\\033]0;%s\\007' \(RemoteShell.quote(title))
        clear
        echo \(RemoteShell.quote(title))
        echo
        echo \(RemoteShell.quote(explanation))
        echo
        echo \(RemoteShell.quote("Commande : " + command))
        echo
        echo 'Appuyez sur Entrée pour lancer, ou sur Ctrl-C (ou fermez cette fenêtre) pour annuler.'
        read -r reponse || exit 1
        \(command)
        status=$?
        echo
        if [ $status -eq 0 ]; then echo \(RemoteShell.quote(after)); else echo "Échec (code $status)."; fi
        """ + "\n"
    }

    /// Nom de fichier du script (« netscope-installer-iperf3.command »).
    public static func scriptFileName(_ tool: InstallableTool?) -> String {
        "netscope-installer-\(tool?.rawValue ?? "homebrew")-\(UUID().uuidString.prefix(6)).command"
    }
}

/// Préparation de l'appareil cible d'un test iperf3 (rappel de la note 17).
public enum IperfServerHelp {
    /// Commande à lancer sur l'autre appareil.
    public static let serverCommand = "iperf3 -s"
    /// Versions Windows : page officielle d'ESnet, qui renvoie vers les compilations Windows.
    public static let windowsURL = URL(string: "https://software.es.net/iperf/obtaining.html#binary-distributions")!
    /// Linux : paquet de la distribution.
    public static let linuxCommand = "sudo apt install iperf3"
}
