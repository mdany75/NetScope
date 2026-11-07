import NetScopeCore
import SwiftUI

/// Réglages › Sites et plages › Plages exclues (note 82) : adresses seules, intervalles ou
/// sous-réseaux jamais sondés, même s'ils sont dans une plage du site (automates, FortiLink,
/// caméras fragiles…). Chaque exclusion a une note facultative. Une exclusion qui couvre toute une
/// plage est signalée. Copiées avec le site (export, import, synchronisation, CSV).
struct RegSiteExclusionsBox: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    let site: Site
    @State private var newText = ""
    @State private var newNote = ""
    @State private var error: String?

    var body: some View {
        let current = sites.site(site.id) ?? site
        let issues = SiteExclusionCheck.issues(current.exclusions, ranges: current.ranges)
        let ranges = current.ranges.compactMap { try? $0.parsed() }
        let excluded = current.excludedAddresses.excludedCount(in: ranges)
        RegSiteBox(title: "Plages exclues") {
            Text("Jamais sondées, même si elles font partie d’une plage du site\u{00A0}: ni ping, ni ARP actif, ni ports, ni SNMP, ni noms (scan, relecture automatique, Scan de ports et Ping continu d’une plage). Un appareil exclu déjà connu reste dans l’inventaire, marqué «\u{00A0}Exclu du scan\u{00A0}».")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if current.exclusions.isEmpty {
                Text("Aucune plage exclue.").font(Theme.small).foregroundStyle(Theme.textSecondary)
            } else {
                Text("\(current.exclusions.count) exclusion\(current.exclusions.count > 1 ? "s" : "") · \(RegFormat.count(excluded))\u{00A0}adresse\(excluded > 1 ? "s" : "") retirée\(excluded > 1 ? "s" : "") des plages du site")
                    .font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                VStack(spacing: 0) {
                    ForEach(Array(current.exclusions.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        row(entry, issues: issues.filter { $0.entryID == entry.id })
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            }
            addForm
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ entry: ExcludedRange, issues: [ExclusionIssue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.text).font(Theme.mono(12, weight: .semibold)).textSelection(.enabled)
                    .lineLimit(1)
                Chip(text: entry.kindLabel)
                Text("\(RegFormat.count(Int(min(entry.addressCount, UInt64(Int.max)))))\u{00A0}adresse\(entry.addressCount > 1 ? "s" : "")")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if !entry.note.isEmpty {
                    Text(entry.note).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                        .help(entry.note)
                }
                Spacer(minLength: 8)
                Button("Retirer") { remove(entry.id) }
                    .controlSize(.small)
                    .help("Retirer «\u{00A0}\(entry.text)\u{00A0}» des plages exclues\u{00A0}: elle sera sondée au prochain scan")
            }
            ForEach(issues) { issue in
                Label(issue.message, systemImage: issue.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(Theme.caption)
                    .foregroundStyle(issue.isWarning ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    /// Une ligne en grande fenêtre ; en petite (note 95), la plage, puis la note et le bouton.
    private var addForm: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 8) {
                rangeField.frame(minWidth: 200, maxWidth: .infinity)
                noteField.frame(minWidth: 140, maxWidth: 240)
                excludeButton
            }
            VStack(alignment: .leading, spacing: 8) {
                rangeField
                HStack(alignment: .bottom, spacing: 8) {
                    noteField.frame(maxWidth: .infinity)
                    excludeButton
                }
            }
        }
    }

    private var rangeField: some View {
        TextField("Plage", text: $newText, prompt: Text("10.93.226.254, 10.93.226.1-50 ou 10.255.1.0/24"))
            .textFieldStyle(.roundedBorder).font(Theme.mono(12))
            .onSubmit(add)
    }

    private var noteField: some View {
        TextField("Note", text: $newNote, prompt: Text("Note (ex. automates, FortiLink)"))
            .textFieldStyle(.roundedBorder)
            .onSubmit(add)
    }

    private var excludeButton: some View {
        Button("Exclure", action: add)
            .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            .fixedSize()
    }

    private func add() {
        error = nil
        guard var current = sites.site(site.id) else { return }
        let entry = ExcludedRange(text: newText, note: newNote)
        guard !entry.text.isEmpty else { return }
        do {
            _ = try entry.intervals()
        } catch {
            self.error = "Plage illisible\u{00A0}: «\u{00A0}\(entry.text)\u{00A0}». \((error as? LocalizedError)?.errorDescription ?? "")"
            return
        }
        let compact = entry.text.replacingOccurrences(of: " ", with: "")
        guard !current.exclusions.contains(where: { $0.text.replacingOccurrences(of: " ", with: "") == compact }) else {
            error = "«\u{00A0}\(entry.text)\u{00A0}» est déjà exclue."
            return
        }
        current.exclusions.append(entry)
        sites.update(current, state: state)
        newText = ""
        newNote = ""
    }

    private func remove(_ id: UUID) {
        guard var current = sites.site(site.id) else { return }
        current.exclusions.removeAll { $0.id == id }
        sites.update(current, state: state)
    }
}
