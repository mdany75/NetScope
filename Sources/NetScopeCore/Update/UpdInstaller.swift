import Darwin
import Foundation

/// Résultat d'une commande externe.
struct UpdShellResult {
    var status: Int32
    var output: String
    var errorOutput: String
}

enum UpdShell {
    /// Lance `tool` avec `arguments` et attend la fin (sortie standard et d'erreur lues en entier).
    static func run(_ tool: String, _ arguments: [String]) -> UpdShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return UpdShellResult(status: -1, output: "", errorOutput: error.localizedDescription)
        }
        // Lecture avant waitUntilExit : un tuyau plein bloquerait la commande.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return UpdShellResult(status: process.terminationStatus,
                              output: String(decoding: outData, as: UTF8.self),
                              errorOutput: String(decoding: errData, as: UTF8.self))
    }
}

// MARK: - Signature

/// Vérifie que l'image disque et l'application qu'elle contient sont signées par l'équipe
/// de NetScope (Developer ID, TeamIdentifier 2F5M9B25A6).
public enum UpdSignature {
    public static let expectedTeamID = "2F5M9B25A6"
    public static let bundleIdentifier = "com.danymenard.netscope"

    /// Une vérification et son résultat, pour la fiche « Vérifications ».
    public struct Check: Hashable, Sendable, Identifiable {
        public var label: String
        public var passed: Bool
        public var detail: String
        public var id: String { label }

        public init(label: String, passed: Bool, detail: String) {
            self.label = label
            self.passed = passed
            self.detail = detail
        }
    }

    /// Champs « clé=valeur » de `codesign -dv` (TeamIdentifier, Identifier, Authority…).
    /// Les autorités sont multiples : elles sont réunies, séparées par « | ».
    public static func parseCodesignDetails(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            if let existing = fields[key] { fields[key] = existing + " | " + value } else { fields[key] = value }
        }
        return fields
    }

    /// Équipe de la signature de `url`, ou nil (non signé, ad hoc).
    public static func teamIdentifier(of url: URL) -> String? {
        let result = UpdShell.run("/usr/bin/codesign", ["-dv", "--verbose=2", url.path])
        guard result.status == 0 else { return nil }
        // codesign écrit les détails sur la sortie d'erreur.
        let team = parseCodesignDetails(result.errorOutput + "\n" + result.output)["TeamIdentifier"]
        return team == "not set" ? nil : team
    }

    /// Image disque : signature valide de l'équipe attendue, puis évaluation Gatekeeper
    /// (notarisation) par spctl.
    public static func verifyDiskImage(at url: URL) -> [Check] {
        var checks: [Check] = []
        let verify = UpdShell.run("/usr/bin/codesign", ["--verify", "--strict", url.path])
        let team = verify.status == 0 ? teamIdentifier(of: url) : nil
        checks.append(Check(label: "Signature de l’image disque",
                            passed: verify.status == 0 && team == expectedTeamID,
                            detail: verify.status != 0 ? firstLine(verify.errorOutput, fallback: "Image non signée")
                                : "Équipe \(team ?? "absente")"))
        let gatekeeper = UpdShell.run("/usr/sbin/spctl", ["--assess", "-t", "open", "--context", "context:primary-signature", url.path])
        checks.append(Check(label: "Notarisation Apple (Gatekeeper)", passed: gatekeeper.status == 0,
                            detail: gatekeeper.status == 0 ? "Acceptée"
                                : firstLine(gatekeeper.errorOutput, fallback: "Refusée")))
        return checks
    }

    /// Application : signature complète valide, même équipe, même identifiant de paquet.
    public static func verifyApplication(at url: URL) -> [Check] {
        var checks: [Check] = []
        let verify = UpdShell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        let details = UpdShell.run("/usr/bin/codesign", ["-dv", "--verbose=2", url.path])
        let fields = parseCodesignDetails(details.errorOutput + "\n" + details.output)
        let team = fields["TeamIdentifier"]
        checks.append(Check(label: "Signature de l’application", passed: verify.status == 0,
                            detail: verify.status == 0 ? "Valide (vérification complète)"
                                : firstLine(verify.errorOutput, fallback: "Invalide")))
        checks.append(Check(label: "Équipe de développeur \(expectedTeamID)", passed: team == expectedTeamID,
                            detail: "Équipe \(team ?? "absente")"))
        let identifier = fields["Identifier"]
        checks.append(Check(label: "Identifiant \(bundleIdentifier)", passed: identifier == bundleIdentifier,
                            detail: identifier ?? "absent"))
        return checks
    }

    private static func firstLine(_ text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? fallback : line
    }
}

// MARK: - Installation

/// Application prête à remplacer l'application courante.
public struct UpdPrepared: Sendable, Hashable {
    /// Copie de l'application, hors de l'image disque (dossier temporaire).
    public var stagedApp: URL
    public var version: String?
    public var checks: [UpdSignature.Check]
    public var allPassed: Bool { checks.allSatisfy(\.passed) }
}

/// Monte l'image disque, vérifie, copie l'application, démonte ; puis remplace l'application
/// courante par un petit script détaché qui attend la fin de NetScope et la relance.
public enum UpdInstaller {
    public static let appName = "NetScope.app"

    /// Paquet .app de l'application en cours, ou nil quand elle tourne hors paquet (swift run).
    public static func runningBundle(_ bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        bundleURL.pathExtension.lowercased() == "app" ? bundleURL.standardizedFileURL : nil
    }

    /// Raison pour laquelle l'installation est impossible, ou nil.
    public static func installBlocker(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        guard let bundle = runningBundle(bundleURL) else {
            return "Installation automatique indisponible : NetScope ne tourne pas depuis une application .app (lancement par swift run). Téléchargez l’image disque depuis GitHub."
        }
        if bundle.path.hasPrefix("/Volumes/") {
            return "NetScope tourne depuis l’image disque : copiez-le d’abord dans le dossier Applications."
        }
        let parent = bundle.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "Pas de droit d’écriture dans \(parent) : installez la mise à jour à la main depuis l’image disque."
        }
        return nil
    }

    /// Point de montage dans la sortie `hdiutil attach -plist`.
    public static func mountPoint(fromHdiutilPlist data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let mount = entity["mount-point"] as? String, !mount.isEmpty {
                return URL(fileURLWithPath: mount, isDirectory: true)
            }
        }
        return nil
    }

    static func attach(_ diskImage: URL) throws -> URL {
        let result = UpdShell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-plist", diskImage.path])
        guard result.status == 0, let mount = mountPoint(fromHdiutilPlist: Data(result.output.utf8)) else {
            throw UpdError.installation("Montage de l’image disque impossible : \(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return mount
    }

    static func detach(_ mount: URL) {
        if UpdShell.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]).status != 0 {
            _ = UpdShell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        }
    }

    /// Vérifie l'image disque et l'application qu'elle contient, puis copie l'application dans un
    /// dossier temporaire. L'image est toujours démontée. Lève une erreur si une vérification échoue.
    public static func prepare(diskImage: URL, expectedVersion: UpdVersion?) throws -> UpdPrepared {
        var checks = UpdSignature.verifyDiskImage(at: diskImage)
        let mount = try attach(diskImage)
        defer { detach(mount) }

        let source = mount.appendingPathComponent(appName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw UpdError.installation("L’image disque ne contient pas « \(appName) ».")
        }
        checks += UpdSignature.verifyApplication(at: source)
        let version = Bundle(url: source)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let expectedVersion {
            let matches = version.flatMap(UpdVersion.init) == expectedVersion
            checks.append(UpdSignature.Check(label: "Version \(expectedVersion)", passed: matches,
                                             detail: "Application en version \(version ?? "inconnue")"))
        }
        guard checks.allSatisfy(\.passed) else {
            let failed = checks.filter { !$0.passed }.map { "\($0.label) (\($0.detail))" }.joined(separator: ", ")
            throw UpdError.verification("Vérification refusée, rien n’a été installé : \(failed).")
        }

        let staging = diskImage.deletingLastPathComponent().appendingPathComponent("prete", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(appName, isDirectory: true)
        let copy = UpdShell.run("/usr/bin/ditto", [source.path, staged.path])
        guard copy.status == 0 else {
            throw UpdError.installation("Copie de l’application impossible : \(copy.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return UpdPrepared(stagedApp: staged, version: version, checks: checks)
    }

    /// Script détaché : attend la fin du processus, remplace l'application avec ditto (l'ancienne
    /// est remise en place si la copie échoue), retire la quarantaine, relance, fait le ménage.
    /// Arguments : PID, application prête, application à remplacer, dossier temporaire.
    public static let relaunchScript = """
    #!/bin/sh
    # Remplacement de NetScope par la mise à jour, lancé par l'application avant de quitter.
    PID="$1"; SRC="$2"; DEST="$3"; WORK="$4"
    i=0
    while kill -0 "$PID" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 600 ]; then exit 1; fi
        sleep 0.2
    done
    OLD="$DEST.ancienne"
    rm -rf "$OLD"
    if mv "$DEST" "$OLD"; then
        if /usr/bin/ditto "$SRC" "$DEST"; then
            rm -rf "$OLD"
        else
            rm -rf "$DEST"
            mv "$OLD" "$DEST"
        fi
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    /usr/bin/open "$DEST"
    rm -rf "$WORK"
    """

    /// Écrit le script et le lance détaché ; l'appelant doit ensuite quitter l'application.
    public static func launchReplacement(prepared: UpdPrepared, destination: URL,
                                         processID: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let work = prepared.stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        let script = work.appendingPathComponent("installer.sh")
        do {
            try relaunchScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            throw UpdError.installation("Script d’installation impossible à écrire : \(error.localizedDescription)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/sh", script.path, String(processID), prepared.stagedApp.path, destination.path, work.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdError.installation("Lancement de l’installation impossible : \(error.localizedDescription)")
        }
    }
}
