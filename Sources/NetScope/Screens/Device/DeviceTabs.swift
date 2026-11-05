import NetScopeCore
import SwiftUI

// Onglets Ports et services, Web, Historique et Notes de la fiche appareil.

// MARK: - Ports et services

struct DevicePortsTab: View {
    @EnvironmentObject private var state: AppState
    let device: Device
    @ObservedObject var model: ToolPortScanModel
    @ObservedObject var store: ToolStore
    /// Tableau standard des ports (note 8), état propre à la fiche appareil.
    @StateObject private var table = PortResultsTable.makeModel(id: "appareil.ports", showProto: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Titre, résumé et commandes sur une ligne ; en petite fenêtre, les commandes passent dessous.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    heading.fixedSize()
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        controls
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if model.isRunning {
                ProgressBar(fraction: model.fraction).padding(.horizontal, 16).padding(.bottom, 10)
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error).padding(.horizontal, 16).padding(.bottom, 10)
            }
            PortResultsTable(host: device.ip.description, results: rows, table: table,
                             probedAt: model.isRunning || model.summary == nil ? nil : model.finishedAt)
                .padding(.horizontal, 16)
            footer
                .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold)).fixedSize()
            Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(ToolPortProfile.allCases) { profile in
                    Button(profile.label) { model.choose(profile) }
                }
            } label: {
                Text("Profil\u{00A0}: " + (model.profile?.label ?? "personnalisé")).font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            ToolColumnsMenu(model: table)
            Button("Copier CSV") { ToolActions.copy(csv) }
                .buttonStyle(.secondary)
                .disabled(rows.isEmpty)
            Group {
                if model.isRunning {
                    Button("Arrêter") { model.cancel() }.buttonStyle(.secondary)
                } else {
                    Button(model.summary == nil ? "Scanner les ports" : "Relancer le scan") { DevicePortsTab.start(model, device: device, state: state, store: store) }
                        .buttonStyle(.primary)
                }
            }
        }
        .fixedSize()
    }

    /// Lance le scan et met à jour les ports ouverts de l'appareil dans l'inventaire.
    static func start(_ model: ToolPortScanModel, device: Device, state: AppState, store: ToolStore) {
        model.target = device.ip.description
        model.start(store: store) { summary in
            guard !summary.wasCancelled, var updated = state.device(withID: device.id) else { return }
            // Un profil partiel (Imprimantes, Caméras…) ne doit pas effacer les ports connus hors de sa liste.
            let scanned = Set(summary.results.map(\.port))
            let kept = updated.openPorts.filter { !scanned.contains($0) }
            updated.openPorts = Array(Set(kept + summary.open.map(\.port))).sorted()
            if summary.results.contains(where: { $0.state != .filtered }) {
                updated.isOnline = true
                updated.lastSeen = Date()
            }
            state.merge([updated])
        }
    }

    private var rows: [PortScanResult] {
        if model.isRunning { return model.openResults }
        if let summary = model.summary {
            let filtered = summary.results.filter { $0.state == .filtered }
            return (summary.open + (filtered.count <= 8 ? filtered : [])).sorted { $0.port < $1.port }
        }
        return device.openPorts.sorted().map { PortScanResult(port: $0, state: .open, banner: "connu (inventaire)") }
    }

    private var title: String {
        let count = rows.filter { $0.state == .open }.count
        return count <= 1 ? "\(count) port ouvert" : "\(count) ports ouverts"
    }

    private var subtitle: String {
        if model.isRunning {
            return "Scan en cours · \(ToolFormat.integer(model.done)) / \(ToolFormat.integer(model.total)) ports"
        }
        if let summary = model.summary, let date = model.finishedAt {
            return "Dernier scan\u{00A0}: \(ToolText.time(date)) · \(ToolFormat.integer(summary.scannedCount)) ports TCP · \(ToolFormat.seconds(summary.duration)) · \(summary.summary)"
        }
        return "Ports relevés par le Scanner · lancez un scan pour lire les bannières"
    }

    private var csv: String {
        (["port;etat;service;banniere;delai_ms"] + rows.sorted(using: table.sortOrder).map {
            "\($0.port);\($0.state.label);\($0.service ?? "");\(($0.banner ?? "").replacingOccurrences(of: ";", with: ","));\($0.rttMs.map { String(format: "%.1f", $0) } ?? "")"
        }).joined(separator: "\n")
    }

    @ViewBuilder private var footer: some View {
        let ports = Set(rows.filter { $0.state == .open }.map(\.port))
        let risky: [(UInt16, String)] = [(23, "Telnet ouvert\u{00A0}: protocole en clair, à désactiver."),
                                         (21, "FTP ouvert\u{00A0}: identifiants en clair."),
                                         (445, "SMB exposé\u{00A0}: vérifier qu’il n’est pas joignable hors du réseau local."),
                                         (3389, "Bureau à distance exposé\u{00A0}: limiter aux postes d’administration.")]
        // Note 6 : accès IP direct de RustDesk (21118 d'un poste, pas le WebSocket d'un serveur).
        let rustDeskDirect: [(UInt16, String)] = RustDeskPorts.role(openPorts: Array(ports)) == .client
            ? [(RustDeskPorts.direct, "Accès IP direct RustDesk ouvert\u{00A0}: session sans serveur ni relais, à réserver au réseau local ou au VPN.")]
            : []
        let findings = risky.filter { ports.contains($0.0) } + rustDeskDirect
        if findings.isEmpty {
            Text("Ports TCP seulement. Une bannière est lue sur SSH, FTP, SMTP, Telnet, VNC et les ports HTTP en clair.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(findings, id: \.0) { finding in
                    HStack(spacing: 10) {
                        Chip(text: "À vérifier", tone: .warning)
                        Text(finding.1).font(Theme.small)
                    }
                }
            }
        }
    }
}

// MARK: - Web

struct DeviceWebTab: View {
    let device: Device
    @ObservedObject var model: DeviceWebModel
    @ObservedObject var store: ToolStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let certificate = model.result?.certificate, !certificate.isTrusted {
                ToolNotice(tone: .warning, title: certificate.isSelfSigned ? "Certificat auto-signé" : "Certificat non approuvé",
                           message: certificateText(certificate))
            }
            VStack(spacing: 0) {
                addressBar
                if let result = model.result {
                    resultBody(result)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                        Text(model.isRunning ? "Analyse en cours…" : "Analysez l’interface web de l’appareil\u{00A0}: code HTTP, titre de la page, serveur et certificat.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        if let error = model.error {
                            Text(error).font(Theme.small).foregroundStyle(Theme.critical).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .padding(20)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            if let result = model.result { footer(result) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.borderStrong).frame(width: 10, height: 10) }
            }
            Image(systemName: model.urlText.hasPrefix("https") ? "lock" : "lock.open")
                .font(.system(size: 11))
                .foregroundStyle(lockColor)
            TextField("", text: $model.urlText, prompt: Text("https://…"))
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
                .autocorrectionDisabled()
                .onSubmit { model.run(store: store) }
                .frame(minWidth: 120)
            Menu {
                ForEach(DeviceSession.webURLs(for: device), id: \.self) { url in
                    Button(url) { model.urlText = url }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Adresses web d’après les ports ouverts")
            Button(model.isRunning ? "Analyse…" : "Analyser") { model.run(store: store) }
                .buttonStyle(.secondary)
                .disabled(model.isRunning)
            Button("Ouvrir dans le navigateur") { ToolActions.open(model.urlText) }
                .buttonStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panelMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var lockColor: Color {
        guard let certificate = model.result?.certificate else { return Theme.textSecondary }
        return certificate.isTrusted ? Theme.success : Theme.warning
    }

    private func resultBody(_ result: HTTPProbeResult) -> some View {
        let tone: Tone = result.statusCode < 300 ? .success : (result.statusCode < 400 ? .accent : .critical)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(result.title ?? "Page sans titre")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(light: 0x1E3A8A, dark: 0x9AAFE9))
                    .textSelection(.enabled)
                Chip(text: result.statusText, tone: tone, mono: true)
                Spacer()
                Text(result.finalURL.absoluteString).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 12) {
                field("Serveur", result.server ?? "non indiqué", mono: true)
                field("Type de contenu", result.contentType ?? "—", mono: true)
                field("Délai de réponse", ToolFormat.milliseconds(result.durationMs), mono: true)
                field("Taille lue", ByteCountFormatter.string(fromByteCount: Int64(result.bodyBytes), countStyle: .file), mono: true)
                field("Redirections", result.redirects.isEmpty ? "aucune" : result.redirects.joined(separator: "\n"), mono: true)
                field("Certificat", result.certificate.map { $0.isTrusted ? "approuvé · \($0.subject)" : "non approuvé · \($0.subject)" } ?? "aucun (HTTP en clair)", mono: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func field(_ label: String, _ value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(mono ? Theme.mono(12, weight: .semibold) : .system(size: 12, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ result: HTTPProbeResult) -> some View {
        HStack(spacing: 16) {
            (Text("Serveur\u{00A0}: ") + Text(result.server ?? "—").font(Theme.mono(12)).foregroundColor(Theme.text))
            (Text("Titre HTML\u{00A0}: ") + Text(result.title ?? "—").foregroundColor(Theme.text))
            if let redirect = result.redirects.first { Text("Redirection \(redirect)") }
            if let date = model.probedAt { Text("Analyse\u{00A0}: \(ToolText.relative(date))") }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
    }

    private func certificateText(_ certificate: HTTPCertificateInfo) -> String {
        var parts = ["Émis pour « \(certificate.subject.isEmpty ? "?" : certificate.subject) »"]
        if let until = certificate.validUntil {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            parts.append("valide jusqu’au \(formatter.string(from: until))")
        }
        parts.append("non approuvé par le trousseau macOS. La connexion est acceptée pour l’analyse seulement.")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Historique

struct DeviceHistoryTab: View {
    let device: Device
    @ObservedObject var store: ToolStore

    private struct Event: Identifiable {
        let id = UUID()
        let date: Date
        let title: String
        let detail: String
        let tag: String
        let tone: Tone
    }

    var body: some View {
        let events = self.events
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Chronologie").font(.system(size: 14, weight: .semibold))
                Text("Suivi depuis le \(DeviceFormat.date(device.firstSeen).prefix(10)) · \(events.count) événement" + (events.count > 1 ? "s" : ""))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Copier") {
                    ToolActions.copy(events.map { "\(DeviceFormat.date($0.date))\t\($0.title)\t\($0.detail)" }.joined(separator: "\n"))
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .top, spacing: 10) {
                        Text(ToolText.day(event.date)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 150, alignment: .leading)
                        VStack(spacing: 0) {
                            Circle().strokeBorder(event.tone.dot, lineWidth: 2).background(Circle().fill(Theme.panel))
                                .frame(width: 11, height: 11).padding(.top, 3)
                            if index < events.count - 1 {
                                Rectangle().fill(Theme.border).frame(width: 1).frame(minHeight: 28)
                            }
                        }
                        .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(event.title).font(Theme.bodySemibold)
                                Chip(text: event.tag, tone: event.tone)
                            }
                            Text(event.detail).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 14)
                        Spacer()
                    }
                }
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var events: [Event] {
        var list: [Event] = []
        let identity = [device.ip.description, device.mac?.formatted(.upperColon), device.vendorLabel].compactMap { $0 }.joined(separator: " · ")
        list.append(Event(date: device.firstSeen, title: "Première détection", detail: identity, tag: "Nouveau", tone: .success))
        if device.lastSeen.timeIntervalSince(device.firstSeen) > 60 {
            list.append(Event(date: device.lastSeen, title: device.isOnline ? "Dernière détection" : "Vu pour la dernière fois",
                              detail: device.isOnline ? "En ligne" + (device.latencyMs.map { " · \(ToolFormat.milliseconds($0))" } ?? "")
                                                      : "Hors ligne depuis \(ToolText.relative(device.lastSeen))",
                              tag: "Disponibilité", tone: device.isOnline ? .neutral : .critical))
        }
        let keys = [device.ip.description, device.mac?.formatted(.upperColon) ?? "", device.hostname ?? ""]
        for recent in store.recents(matching: keys) {
            list.append(Event(date: recent.date, title: recent.displayTitle, detail: recent.summary, tag: recent.status.label,
                              tone: recent.status == .ok ? .accent : recent.status.tone))
        }
        if let mac = device.mac?.formatted(.upperColon) {
            for wake in store.wakeLog where wake.mac == mac {
                list.append(Event(date: wake.date, title: "Wake-on-LAN", detail: wake.detail, tag: wake.status.label, tone: wake.status.tone))
            }
        }
        return list.sorted { $0.date > $1.date }
    }
}

// MARK: - Notes

struct DeviceNotesTab: View {
    let device: Device
    @ObservedObject var notes: DeviceNotesStore
    @State private var draft = ""
    @State private var loadedKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes du technicien").font(.system(size: 14, weight: .semibold))
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 240)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                .onChange(of: draft) { _, text in
                    if loadedKey == DeviceNotesStore.key(for: device), text != notes.note(for: device) {
                        notes.setNote(text, for: device)
                    }
                }
            HStack(spacing: 10) {
                Text("\(draft.count) caractères · " + (notes.isSaved(device) ? "enregistré localement" : "rien d’enregistré"))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Ajouter l’horodatage") {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm"
                    let stamp = formatter.string(from: Date()) + " — "
                    draft = draft.isEmpty ? stamp : stamp + "\n" + draft
                }
                .buttonStyle(.secondary)
                Button("Enregistrer") { notes.setNote(draft, for: device) }
                    .buttonStyle(.primary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .onAppear(perform: load)
        .onChange(of: device.id) { _, _ in load() }
    }

    private func load() {
        draft = notes.note(for: device)
        loadedKey = DeviceNotesStore.key(for: device)
    }
}

extension DeviceNotesStore {
    func isSaved(_ device: Device) -> Bool { !note(for: device).isEmpty }
}
