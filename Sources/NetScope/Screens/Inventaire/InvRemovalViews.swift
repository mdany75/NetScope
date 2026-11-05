import AppKit
import NetScopeCore
import SwiftUI

// Note 10 : retirer (archiver ou supprimer définitivement), déplacer vers un autre site, et fiche
// d'un appareil archivé.

/// Sous-menu « Déplacer vers un autre site › » : tous les sites, sauf celui des lignes choisies.
struct InvMoveMenu: View {
    @ObservedObject private var sites = SiteModel.shared
    let rows: [SiteScopedRecord]
    let onPick: (String) -> Void

    var body: some View {
        let from = Set(rows.map(\.siteKey))
        let targets = sites.sortedSites.map { (key: SiteFiles.key(for: $0.id), name: $0.displayName) }
            .filter { !(from.count == 1 && from.contains($0.key)) }
        Menu("Déplacer vers un autre site") {
            ForEach(targets, id: \.key) { target in
                Button(target.name) { onPick(target.key) }
            }
        }
        .disabled(targets.isEmpty)
    }
}

enum InvDialogs {
    /// « « Siège » », ou « Siège (2), Entrepôt Laval (1) »
    static func siteSummary(_ rows: [SiteScopedRecord]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for row in rows {
            if counts[row.siteName] == nil { order.append(row.siteName) }
            counts[row.siteName, default: 0] += 1
        }
        if order.count == 1 { return "«\u{00A0}\(order[0])\u{00A0}»" }
        return order.map { "\($0) (\(counts[$0] ?? 0))" }.joined(separator: ", ")
    }

    private static func names(_ rows: [SiteScopedRecord]) -> String {
        rows.prefix(3).map(\.record.displayName).joined(separator: ", ") + (rows.count > 3 ? "…" : "")
    }

    /// Retirer de l'inventaire : « Archiver » (par défaut), « Supprimer définitivement » ou annuler ;
    /// case « Ne plus réajouter ». Nil : annulé.
    @MainActor
    static func confirmRemove(_ chosen: [SiteScopedRecord]) -> (archive: Bool, exclude: Bool)? {
        let count = chosen.count
        let several = Set(chosen.map(\.siteKey)).count > 1
        let attachments = chosen.reduce(0) { $0 + $1.record.attachmentList.count }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count > 1 ? "Retirer \(count) appareils de l’inventaire\u{00A0}?" : "Retirer «\u{00A0}\(names(chosen))\u{00A0}» de l’inventaire\u{00A0}?"
        alert.informativeText = (count > 1 ? names(chosen) + "\n\n" : "")
            + (several ? "Sites touchés\u{00A0}: " : "Site touché\u{00A0}: ") + siteSummary(chosen) + " (les autres sites ne changent pas).\n\n"
            + "Archiver\u{00A0}: la fiche, ses notes, sa garantie et son historique vont dans «\u{00A0}Archivés\u{00A0}», restaurables à tout moment.\n"
            + "Supprimer définitivement\u{00A0}: tout est effacé"
            + (attachments > 0 ? " (les \(attachments) pièce\(attachments > 1 ? "s" : "") jointe\(attachments > 1 ? "s" : "") vont dans la corbeille)" : "") + ".\n\n"
            + "Sans «\u{00A0}Ne plus réajouter\u{00A0}», " + (count > 1 ? "ces appareils reviendront" : "l’appareil reviendra")
            + " si un prochain scan de leur site les revoit (et si l’ajout automatique est activé). Vous pourrez annuler juste après (⌘Z)."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = count > 1 ? "Ne plus réajouter ces appareils (liste d’exclusion du site)"
            : "Ne plus réajouter cet appareil (liste d’exclusion du site)"
        alert.suppressionButton?.state = .off
        alert.addButton(withTitle: "Archiver")
        let delete = alert.addButton(withTitle: "Supprimer définitivement")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Annuler").keyEquivalent = "\u{1b}"
        let answer = alert.runModal()
        let exclude = alert.suppressionButton?.state == .on
        switch answer {
        case .alertFirstButtonReturn: return (true, exclude)
        case .alertSecondButtonReturn: return (false, exclude)
        default: return nil
        }
    }

    /// Supprimer définitivement des appareils archivés.
    @MainActor
    static func confirmPurge(_ chosen: [SiteScopedRecord]) -> Bool {
        let count = chosen.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count > 1 ? "Supprimer définitivement \(count) appareils archivés\u{00A0}?"
            : "Supprimer définitivement «\u{00A0}\(names(chosen))\u{00A0}»\u{00A0}?"
        alert.informativeText = (count > 1 ? names(chosen) + "\n\n" : "")
            + "Leur fiche et leur historique sont effacés des archives de " + siteSummary(chosen)
            + "\u{00A0}; leurs pièces jointes vont dans la corbeille. Vous pourrez annuler juste après (⌘Z)."
        let delete = alert.addButton(withTitle: "Supprimer définitivement")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Annuler")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Déplacer vers un autre site : ce qui sera déplacé et ce qui restera (jamais de fusion).
    @MainActor
    static func confirmMove(_ chosen: [SiteScopedRecord], to name: String, refusals: [InvTransferRefusal]) -> Bool {
        let movable = chosen.count - refusals.count
        let alert = NSAlert()
        alert.alertStyle = .informational
        guard movable > 0 else {
            alert.messageText = "Rien à déplacer vers «\u{00A0}\(name)\u{00A0}»"
            alert.informativeText = refusals.prefix(5).map { "• \($0.name)\u{00A0}: \($0.reason)" }.joined(separator: "\n")
                + "\n\nLes inventaires de deux sites ne sont jamais fusionnés."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        alert.messageText = movable > 1 ? "Déplacer \(movable) appareils vers «\u{00A0}\(name)\u{00A0}»\u{00A0}?"
            : "Déplacer «\u{00A0}\(chosen.first { row in !refusals.contains { $0.key == row.record.key } }?.record.displayName ?? "")\u{00A0}» vers «\u{00A0}\(name)\u{00A0}»\u{00A0}?"
        var text = "Fiche, notes, garantie, historique et pièces jointes passent dans l’inventaire de «\u{00A0}\(name)\u{00A0}» et quittent "
            + siteSummary(chosen) + ". Si un scan de l’ancien site revoit l’appareil, il y reviendra comme un nouvel appareil (même MAC signalée sur les deux sites)."
        if !refusals.isEmpty {
            text += "\n\nRestent où ils sont (jamais de fusion entre sites)\u{00A0}:\n"
                + refusals.prefix(5).map { "• \($0.name)\u{00A0}: \($0.reason)" }.joined(separator: "\n")
                + (refusals.count > 5 ? "\n…" : "")
        }
        alert.informativeText = text + "\n\nVous pourrez annuler juste après (⌘Z)."
        alert.addButton(withTitle: "Déplacer")
        alert.addButton(withTitle: "Annuler")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Fiche d'un appareil archivé : quand, pourquoi, ce qu'on sait de lui ; Restaurer ou Supprimer.
struct InvArchivePanel: View {
    let entry: InvArchiveEntry
    let siteName: String
    let now: Date
    let onRestore: () -> Void
    let onPurge: () -> Void

    var body: some View {
        let record = entry.record
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.neutralSoft)
                        Image(systemName: "archivebox").font(.system(size: 17)).foregroundStyle(Theme.neutralText)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.displayName).font(Theme.panelTitle)
                        Text("Archivé le \(InvFormat.stamp(entry.date)) · site «\u{00A0}\(siteName)\u{00A0}» · \(entry.events.count) événement\(entry.events.count > 1 ? "s" : "") gardé\(entry.events.count > 1 ? "s" : "")")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(action: onRestore) { Label("Restaurer", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.primary)
                    Button(role: .destructive, action: onPurge) { Label("Supprimer définitivement…", systemImage: "trash") }
                        .buttonStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    row("Adresse", record.addressLabel + " · " + (record.mac?.formatted(.upperColon) ?? "MAC inconnue"), mono: true)
                    row("Fabricant · type", record.vendorLabel + " · " + record.type.label)
                    row("Dernière vue", InvFormat.relative(record.lastSeen, now: now))
                    if !record.annotations.location.isEmpty { row("Local", record.annotations.location) }
                    if !record.annotations.owner.isEmpty { row("Responsable", record.annotations.owner) }
                    if let hardware = record.annotations.hardware {
                        row("Garantie", hardware.warranty(now: now).label
                            + (hardware.serialNumber.isEmpty ? "" : " · n° de série \(hardware.serialNumber)"))
                    }
                    if !record.attachmentList.isEmpty {
                        row("Pièces jointes", record.attachmentList.map(\.fileName).joined(separator: ", "))
                    }
                    if !record.annotations.notes.isEmpty { row("Notes", record.annotations.notes) }
                }
                Text("Restaurer remet la fiche telle qu’elle était (notes, garantie, historique, pièces jointes) dans l’inventaire de son site.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
            Text(value).font(mono ? Theme.mono(12) : Theme.small).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
