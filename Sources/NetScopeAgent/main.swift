import Foundation
import NetScopeCore

// NetScopeAgent (note 64) : agent sans fenêtre, enregistré par l'app (Réglages › Surveillance) avec
// SMAppService (LaunchAgent du paquet : Contents/Library/LaunchAgents). Il ne fait rien d'autre que
// les sondes réseau de Surveillance, le récepteur Syslog et les scans planifiés, et seulement quand
// NetScope est fermé. Il ne démarre jamais en démonstration ni pendant les captures ou les tests.

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print("NetScopeAgent \(AgentService.version)")
    exit(0)
}
if arguments.contains("--demo") || arguments.contains("--snapshot") {
    exit(0)
}
// Lancé par launchd (étiquette du LaunchAgent) ; « --premier-plan » permet un essai à la main.
let launchedByLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == AutomationFiles.agentLabel
guard launchedByLaunchd || arguments.contains("--premier-plan") else {
    FileHandle.standardError.write(Data("NetScopeAgent est lancé par macOS : activez-le dans NetScope, Réglages › Surveillance.\n".utf8))
    exit(64)
}

signal(SIGPIPE, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let service = AgentService(files: .standard)
// Arrêt demandé par macOS (désactivation dans Réglages, fermeture de session) : état noté, puis sortie.
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task {
        await service.stop()
        exit(0)
    }
}
termination.resume()
Task { await service.run() }
dispatchMain()
