import NetScopeCore
import SwiftUI

// Blocs de l'outil « État des services » : détail du service choisi, incidents en cours, historique.

/// Cadre commun des blocs (fond gris clair, bordure fine).
private struct SvcBlock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

// MARK: - Détail du service

struct SvcServiceDetail: View {
    let service: SvcService
    @ObservedObject private var svc = SvcStore.shared

    var body: some View {
        let snapshot = svc.snapshot(service.id)
        SvcBlock {
            header(snapshot)
            if let snapshot {
                verdict(snapshot)
                endpoints(snapshot)
                feed(snapshot)
            } else {
                Text(svc.checking.contains(service.id) ? "Vérification en cours…" : "Pas encore vérifié\u{00A0}: «\u{00A0}Actualiser\u{00A0}» lance la vérification.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func header(_ snapshot: SvcSnapshot?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title(snapshot)
                Spacer(minLength: 8)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                title(snapshot)
                actions
            }
        }
    }

    private func title(_ snapshot: SvcSnapshot?) -> some View {
        HStack(spacing: 8) {
            Text(service.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
            Chip(text: SvcTone.label(snapshot?.verdict.health, checking: svc.checking.contains(service.id)),
                 tone: SvcTone.tone(snapshot?.verdict.health))
            if let snapshot {
                Text("à \(ToolText.time(snapshot.date, now: svc.now))").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Vérifier") { svc.refresh(service.id) }
                .buttonStyle(.secondary)
                .disabled(svc.checking.contains(service.id) || svc.isSimulated)
            Button {
                ToolActions.open(service.pageURL)
            } label: {
                Label("Page officielle", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.secondary)
            .help(service.pageURL)
        }
        .fixedSize()
    }

    private func verdict(_ snapshot: SvcSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if snapshot.verdict.side != .none {
                    Text(snapshot.verdict.side == .ours ? "CHEZ NOUS" : "CHEZ EUX")
                        .font(.system(size: 10, weight: .bold)).kerning(0.4)
                        .foregroundStyle(snapshot.verdict.side == .ours ? Theme.critical : Theme.warning)
                }
                Text(snapshot.verdict.headline).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = snapshot.verdict.detail {
                Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func endpoints(_ snapshot: SvcSnapshot) -> some View {
        if !snapshot.endpoints.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ToolFieldLabel("Depuis ce réseau")
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.endpoints.enumerated()), id: \.offset) { index, endpoint in
                        endpointRow(endpoint)
                            .overlay(alignment: .top) {
                                if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            }
        }
    }

    private func endpointRow(_ endpoint: SvcEndpointResult) -> some View {
        // Mesures à droite de l'adresse quand la place suffit, sinon dessous (petite fenêtre).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                hostLabel(endpoint)
                Spacer(minLength: 6)
                outcome(endpoint)
            }
            .frame(height: 28)
            VStack(alignment: .leading, spacing: 3) {
                hostLabel(endpoint)
                outcome(endpoint).padding(.leading, 15)
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 10)
    }

    private func hostLabel(_ endpoint: SvcEndpointResult) -> some View {
        HStack(spacing: 8) {
            Circle().fill(endpoint.isReachable ? Theme.successDot : Theme.criticalBadge).frame(width: 7, height: 7)
            Text(endpoint.host).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle)
                .help(endpoint.addresses.joined(separator: ", "))
        }
    }

    @ViewBuilder private func outcome(_ endpoint: SvcEndpointResult) -> some View {
        if endpoint.isReachable {
            measures(endpoint)
        } else {
            Text(endpoint.failure.map { $0.shortLabel + " · " + $0.cause } ?? "Échec")
                .font(Theme.small).foregroundStyle(Theme.critical)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(endpoint.detail ?? "")
        }
    }

    private func measures(_ endpoint: SvcEndpointResult) -> some View {
        HStack(spacing: 10) {
            measure("DNS", endpoint.dnsMs)
            measure("TLS", endpoint.tlsMs)
            measure("HTTPS", endpoint.httpMs)
            Text(endpoint.httpStatus.map(String.init) ?? "—")
                .font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.neutralText)
                .padding(.horizontal, 5).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(Theme.neutralSoft))
                .help("Code HTTP de la première réponse (une redirection ou un refus prouvent que le service répond)")
        }
        .fixedSize()
    }

    private func measure(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Text(value.map(ToolFormat.milliseconds) ?? "—").font(Theme.mono(11)).foregroundStyle(Theme.text)
        }
    }

    private func feed(_ snapshot: SvcSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ToolFieldLabel("Page d’état")
            HStack(spacing: 6) {
                Text(snapshot.feed?.description ?? (service.format == .none ? "Aucune page lisible pour ce service" : "Non lue"))
                    .font(Theme.small).foregroundStyle(Theme.text)
                if let source = snapshot.feedSource {
                    Text("· \(source)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
            }
            if let components = snapshot.feed?.components, !components.isEmpty {
                StandardTagList(tags: components.map { "\($0.name) · \($0.health.label.lowercased())" },
                                colors: { tag in tag.contains("panne") ? (Theme.critical, Theme.criticalSoft) : (Theme.warning, Theme.warningSoft) })
            } else if !service.components.isEmpty {
                Text("Suivi\u{00A0}: " + service.components.joined(separator: ", "))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            if let error = snapshot.feedError {
                Text(error).font(Theme.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Incidents en cours

struct SvcIncidentList: View {
    @ObservedObject private var svc = SvcStore.shared

    var body: some View {
        let items = svc.activeIncidents
        VStack(alignment: .leading, spacing: 8) {
            ToolFieldLabel("Incidents en cours (\(items.count))")
            if items.isEmpty {
                Text(svc.currentSnapshots.isEmpty ? "Les incidents publiés par les pages d’état apparaîtront ici."
                     : "Aucun incident publié par les services suivis.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            ForEach(items, id: \.incident.id) { item in
                card(item.service, item.incident)
            }
        }
    }

    private func card(_ service: SvcService, _ incident: SvcIncident) -> some View {
        let tone = SvcTone.tone(incident.impact)
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(tone.dot).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(incident.title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Chip(text: incident.status, tone: tone)
                }
                Text(meta(service, incident)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let update = incident.latestUpdate, !update.isEmpty {
                    Text(update).font(Theme.small).foregroundStyle(Theme.neutralText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let url = incident.url {
                    Button {
                        ToolActions.open(url)
                    } label: {
                        Label("Page officielle", systemImage: "arrow.up.forward")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentStrong)
                    .help(url)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .onTapGesture { svc.selectedServiceID = service.id }
    }

    /// « Microsoft 365 · Teams · début 09:12 · mise à jour 14:05 ».
    private func meta(_ service: SvcService, _ incident: SvcIncident) -> String {
        var parts = [service.name]
        if !incident.affected.isEmpty { parts.append(incident.affected.prefix(4).joined(separator: ", ")) }
        if let started = incident.started { parts.append("début " + ToolText.day(started, now: svc.now).replacingOccurrences(of: "Auj. ", with: "")) }
        if let updated = incident.updated { parts.append("mise à jour " + ToolText.relative(updated, now: svc.now)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Historique

struct SvcHistoryList: View {
    @ObservedObject private var svc = SvcStore.shared
    @State private var showAll = false

    var body: some View {
        let events = svc.history.events
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ToolFieldLabel("Historique (30 jours)")
                Spacer()
                if events.count > 6 {
                    Button(showAll ? "Réduire" : "Tout afficher (\(events.count))") { showAll.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accentStrong)
                }
            }
            if events.isEmpty {
                Text("Les incidents apparus et résolus, et les pertes d’accès depuis ce réseau, seront notés ici.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.prefix(showAll ? 60 : 6).enumerated()), id: \.element.id) { index, event in
                        row(event)
                            .overlay(alignment: .top) {
                                if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            }
        }
    }

    private func row(_ event: SvcHistoryEvent) -> some View {
        HStack(spacing: 8) {
            Text(ToolText.day(event.date, now: svc.now)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                .frame(width: 112, alignment: .leading)
                .lineLimit(1)
            Chip(text: event.kindLabel, tone: tone(event))
            Text(event.serviceName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1).fixedSize()
            Text(event.title).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
                .help(event.title)
            Spacer(minLength: 0)
            if let url = event.url {
                Button { ToolActions.open(url) } label: {
                    Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentStrong)
                .help(url)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func tone(_ event: SvcHistoryEvent) -> Tone {
        switch event.kind {
        case .incident: return SvcTone.tone(event.health)
        case .unreachable: return .critical
        case .resolved, .reachable: return .success
        }
    }
}
