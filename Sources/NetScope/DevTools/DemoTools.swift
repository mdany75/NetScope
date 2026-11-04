import Foundation
import NetScopeCore

/// Outils externes en démonstration (`--demo`) : présence fixe, pour des captures identiques
/// d'un Mac à l'autre. NETSCOPE_DEMO_MISSING_TOOLS=1 les montre absents avec Homebrew présent,
/// NETSCOPE_DEMO_MISSING_TOOLS=nobrew absents sans Homebrew (vérifier l'encadré « Installer »).
enum DemoTools {
    static func presence(for tool: InstallableTool) -> ToolPresence? {
        guard Launcher.isDemo else { return nil }
        switch ProcessInfo.processInfo.environment["NETSCOPE_DEMO_MISSING_TOOLS"] {
        case "1": return .missingWithHomebrew(brew: "/opt/homebrew/bin/brew")
        case "nobrew": return .missingWithoutHomebrew
        default:
            // Démonstration ordinaire : iperf3 et telnet présents, CLI d'Ookla présent aussi.
            return .installed(path: tool.candidatePaths.first ?? "/opt/homebrew/bin/\(tool.rawValue)")
        }
    }
}
