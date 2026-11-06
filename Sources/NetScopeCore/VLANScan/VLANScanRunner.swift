import Foundation

// Note 90 : lancement des commandes networksetup. La création et le retrait passent par
// osascript « with administrator privileges » : macOS demande lui-même le mot de passe, au
// moment où la commande est lancée ; NetScope ne le voit jamais. Jamais appelé en démonstration,
// pendant les captures ni dans les tests.
public enum VLANScanRunner {
    public static let osascript = "/usr/bin/osascript"

    /// Interfaces VLAN existantes (lecture, sans droits administrateur).
    public static func listVLANs() async -> [VLANEntry] {
        let result = await ProcessRunner.run(VLANScanCommands.networksetup, ["-listVLANs"],
                                             environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 15)
        return VLANEntry.parseList(result.stdout)
    }

    /// Variante bloquante de `listVLANs()`, pour la fermeture de l'app (lecture, sans droits).
    public static func listVLANsNow() -> [VLANEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: VLANScanCommands.networksetup)
        process.arguments = ["-listVLANs"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return VLANEntry.parseList(String(decoding: data, as: UTF8.self))
    }

    /// Script avec droits administrateur ; nil si réussi, sinon le message d'erreur (refus compris).
    public static func runPrivileged(_ script: String, prompt: String, timeout: TimeInterval = 120) async -> String? {
        let apple: String
        do { apple = try PrivilegedCapture.appleScript(for: script, prompt: prompt) } catch { return "Commande refusée." }
        let result = await ProcessRunner.run(osascript, ["-e", apple], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                                             timeout: timeout)
        if result.status == 0 { return nil }
        return message(stderr: result.stderr, timedOut: result.timedOut)
    }

    /// Variante bloquante, pour la fermeture de l'app (l'interface doit être retirée avant de quitter).
    public static func runPrivilegedNow(_ script: String, prompt: String) -> String? {
        guard let apple = try? PrivilegedCapture.appleScript(for: script, prompt: prompt) else { return "Commande refusée." }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascript)
        process.arguments = ["-e", apple]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 ? nil : message(stderr: text, timedOut: false)
    }

    /// Erreur d'osascript en français (« User canceled » : autorisation refusée).
    public static func message(stderr: String, timedOut: Bool) -> String {
        if timedOut { return "Délai dépassé (fenêtre d’autorisation restée ouverte)." }
        let lower = stderr.lowercased()
        if lower.contains("-128") || lower.contains("user canceled") || lower.contains("annulé") {
            return "Autorisation refusée\u{00A0}: rien n’a été modifié."
        }
        let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "networksetup a échoué." : String(line.prefix(200))
    }
}
