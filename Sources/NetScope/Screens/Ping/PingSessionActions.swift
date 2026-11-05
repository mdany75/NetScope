import AppKit
import Foundation
import NetScopeCore
import UniformTypeIdentifiers

// Note 78 (0.26.0) : session du ping continu enregistrée et rouverte, seuil de lenteur par
// cible, disposition (cartes ou tableau compact) et rapport « pour le fournisseur Internet ».
// La dernière session est gardée dans ~/Library/Application Support/NetScope/ping-session.json
// (jamais en démonstration ni en capture) ; « Enregistrer la session… » écrit un fichier
// .netscope-ping à l'endroit choisi.

extension PingController {
    /// Les cibles s'affichent en tableau compact.
    var usesTable: Bool { layoutChoice.usesTable(targetCount: targets.count) }

    // MARK: Seuil de lenteur

    func setThreshold(_ value: Double, for id: PingTarget.ID) {
        guard let target = targets.first(where: { $0.id == id }), let value = PingThreshold.clamped(value),
              value != target.thresholdMs else { return }
        update(id) { $0.thresholdMs = value }
        log(.info, target.addressLabel, "seuil de lenteur réglé à \(PingThreshold.label(value))")
    }

    /// Seuil d'origine de la cible (selon son adresse).
    func defaultThreshold(for target: PingTarget) -> Double {
        PingEventDetector.defaultThreshold(for: target.address)
    }

    // MARK: Session

    /// Cibles et réglages actuels (sans l'historique des mesures).
    var sessionFile: PingSessionFile {
        PingSessionFile(interval: interval, payloadSize: payloadSize, soundOnLoss: soundOnLoss, notifyChanges: notifyChanges,
                        layout: layoutChoice,
                        targets: targets.map {
                            PingSessionFile.Target(input: $0.input, name: $0.name == $0.input ? "" : $0.name, role: $0.role,
                                                   thresholdMs: $0.thresholdMs, isPaused: $0.isPaused)
                        })
    }

    /// Change à chaque modification à retenir (enregistrement automatique de la dernière session).
    var sessionSignature: String {
        let file = sessionFile
        let parts = file.targets.map { "\($0.input)|\($0.name)|\($0.thresholdMs ?? 0)|\($0.isPaused)" }
        return parts.joined(separator: ";") + "#\(file.interval)|\(file.payloadSize)|\(file.soundOnLoss)|\(file.notifyChanges)|\(file.layout.rawValue)"
    }

    /// Remplace les cibles et réglages par ceux d'une session ; les mesures repartent de zéro.
    func applySession(_ file: PingSessionFile, origin: String) {
        for target in targets { remove(target.id, quietly: true) }
        setInterval(file.interval)
        setPayloadSize(file.payloadSize)
        soundOnLoss = file.soundOnLoss
        notifyChanges = file.notifyChanges
        layoutChoice = file.layout
        for saved in file.targets {
            guard add(saved.input, name: saved.name.isEmpty ? nil : saved.name, role: saved.role.isEmpty ? nil : saved.role, log: false),
                  let target = targets.last else { continue }
            if let threshold = saved.thresholdMs { update(target.id) { $0.thresholdMs = threshold } }
            if saved.isPaused { togglePause(target.id) }
        }
        log(.info, "Session", "session rouverte (\(origin))\u{00A0}: \(file.summary)")
    }

    // MARK: Fichiers

    static var lastSessionURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("NetScope", isDirectory: true).appendingPathComponent("ping-session.json")
    }

    /// Dernière session enregistrée automatiquement (nil en démonstration, ou s'il n'y en a pas).
    var lastSession: PingSessionFile? {
        guard !isSimulated, let url = Self.lastSessionURL, let data = try? Data(contentsOf: url),
              let file = try? PingSessionFile.decode(data), !file.targets.isEmpty else { return nil }
        return file
    }

    /// Garde la session actuelle pour « Rouvrir la dernière session » (rien en démonstration ;
    /// une session vidée n'efface pas la précédente).
    func autosave() {
        guard !isSimulated, !targets.isEmpty, let url = Self.lastSessionURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sessionFile.encoded().write(to: url, options: .atomic)
        } catch {
            AppLog.shared.error("Ping", "Enregistrement impossible de \(url.path)\u{00A0}: \(error.localizedDescription)")
        }
    }

    func reopenLastSession() {
        guard let file = lastSession else { return }
        applySession(file, origin: "dernière session")
    }

    private static var sessionType: UTType {
        UTType(filenameExtension: PingSessionFile.fileExtension, conformingTo: .json) ?? .json
    }

    func saveSessionAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.sessionType]
        panel.nameFieldStringValue = "ping-continu.\(PingSessionFile.fileExtension)"
        panel.title = "Enregistrer la session"
        panel.message = "Cibles et réglages du ping continu (pas les mesures)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sessionFile.encoded().write(to: url, options: .atomic)
            log(.info, "Session", "session enregistrée\u{00A0}: \(url.lastPathComponent) (\(sessionFile.summary))")
        } catch {
            log(.alerte, "Session", "échec de l’enregistrement\u{00A0}: \(error.localizedDescription)")
        }
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.sessionType, .json]
        panel.allowsMultipleSelection = false
        panel.title = "Ouvrir une session de ping continu"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try PingSessionFile.decode(try Data(contentsOf: url))
            applySession(file, origin: url.lastPathComponent)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log(.alerte, "Session", "ouverture impossible de \(url.lastPathComponent)\u{00A0}: \(message)")
        }
    }

    // MARK: Rapport pour le fournisseur Internet

    var ispReport: PingISPReport {
        let inputs = targets.map {
            PingISPReport.Input(name: $0.name, address: $0.addressLabel, role: $0.role, thresholdMs: $0.thresholdMs, log: $0.longLog)
        }
        return PingISPReport.make(inputs, generatedAt: Date())
    }

    var hasLongLog: Bool { targets.contains { !$0.longLog.isEmpty } }

    func exportISPReport() {
        let report = ispReport
        guard !report.targets.isEmpty, let data = PingISPReportPDF.render(report) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "rapport-fournisseur-internet-\(stamp.string(from: Date())).pdf"
        panel.title = "Rapport pour le fournisseur Internet"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            log(.info, "Export", "rapport pour le fournisseur Internet enregistré\u{00A0}: \(url.lastPathComponent)")
        } catch {
            log(.alerte, "Export", "échec de l’enregistrement\u{00A0}: \(error.localizedDescription)")
        }
    }

    func copyISPReportText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ispReport.text(), forType: .string)
        log(.info, "Export", "rapport pour le fournisseur Internet copié (texte)")
    }
}
