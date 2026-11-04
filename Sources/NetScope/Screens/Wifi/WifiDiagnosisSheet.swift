import AppKit
import NetScopeCore
import SwiftUI

// Note 47 : bouton « Diagnostiquer » réutilisable (client, borne, SSID) et feuille du résultat :
// verdict d'ensemble, cause la plus probable, actions numérotées, causes avec leurs preuves,
// suivi dans le temps, « Copier » et « Ajouter au rapport du site ». Lecture seule.

extension WifiVerdict {
    var tone: Tone {
        switch self {
        case .problem: return .critical
        case .watch: return .warning
        case .ok: return .success
        case .notMeasured: return .neutral
        }
    }

    var symbol: String {
        switch self {
        case .problem: return "exclamationmark.octagon.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.circle.fill"
        case .notMeasured: return "questionmark.circle"
        }
    }
}

extension WifiCause {
    var symbol: String {
        switch self {
        case .signal: return "wifi.exclamationmark"
        case .sticky: return "arrow.triangle.swap"
        case .channel: return "square.stack.3d.up"
        case .interference: return "antenna.radiowaves.left.and.right"
        case .width: return "arrow.left.and.right"
        case .dfs: return "dot.radiowaves.up.forward"
        case .load: return "person.3"
        case .slowClients: return "tortoise"
        case .client: return "laptopcomputer"
        case .band: return "waveform"
        case .connection: return "key"
        case .dhcp: return "number"
        case .network: return "globe"
        case .uplink: return "cable.connector"
        case .wan: return "network"
        case .ssid: return "wifi"
        }
    }
}

/// Pastille de verdict (« Problème », « À surveiller », « OK »).
struct WifiVerdictPill: View {
    let verdict: WifiVerdict
    var large = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: verdict.symbol).font(.system(size: large ? 11 : 9, weight: .bold))
            Text(verdict.label).font(.system(size: large ? 12 : 10.5, weight: .bold))
        }
        .foregroundStyle(verdict.tone.foreground)
        .padding(.horizontal, large ? 9 : 6)
        .padding(.vertical, large ? 4 : 2)
        .background(Capsule().fill(verdict.tone.background))
        .fixedSize()
    }
}

// MARK: - Bouton

/// Bouton « Diagnostiquer » d'un client, d'une borne ou d'un SSID (fiche du client, fiche Appareil,
/// Wi-Fi › FortiAP). Ouvre la feuille du diagnostic ; le style du bouton est laissé à l'appelant.
struct WifiDiagnoseButton: View {
    let target: WifiDiagnosisTarget
    var title: String
    var compact = false
    @State private var shown: WifiDiagnosisTarget?

    init(client: FortiWifiClient, details: WifiClientDetails? = nil, title: String = "Diagnostiquer", compact: Bool = false) {
        target = .client(client, details: details)
        self.title = title
        self.compact = compact
    }

    init(ap: FortiManagedAP, title: String = "Diagnostiquer la borne", compact: Bool = false) {
        target = .ap(ap)
        self.title = title
        self.compact = compact
    }

    init(ssid: FortiSSID, title: String = "Diagnostiquer le SSID", compact: Bool = false) {
        target = .ssid(ssid)
        self.title = title
        self.compact = compact
    }

    var body: some View {
        Button { shown = target } label: {
            if compact {
                Label(title, systemImage: "stethoscope").labelStyle(.iconOnly).font(.system(size: 11, weight: .semibold))
            } else {
                Label(title, systemImage: "stethoscope")
            }
        }
        .accessibilityLabel(title)
        .help((compact ? title + ". " : "") + "Vérifie chaque cause possible d’un problème Wi-Fi (signal, canal, charge, client, authentification, DHCP, réseau) et propose quoi faire. Lecture seule.")
        .wifiDiagnosisSheet(item: $shown)
    }
}

extension View {
    /// Feuille du diagnostic Wi-Fi d'une cible.
    func wifiDiagnosisSheet(item: Binding<WifiDiagnosisTarget?>) -> some View {
        sheet(item: item) { target in
            WifiDiagnosisSheet(target: target, dismiss: { item.wrappedValue = nil })
        }
    }
}

// MARK: - Feuille

struct WifiDiagnosisSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = WifiDiagnosisStore.shared
    let target: WifiDiagnosisTarget
    /// Dessinée dans la page (captures) : pas de mesure différée, hauteur donnée par le parent.
    var inline = false
    let dismiss: () -> Void

    @State private var result: WifiDiagnosisResult?
    @State private var measuring = false
    @State private var copied = false
    @State private var showOK = false
    @State private var showUnchecked = false
    @State private var task: Task<Void, Never>?

    static let width: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                if let result {
                    content(result)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                } else {
                    ProgressView().padding(40)
                }
            }
            Divider()
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: Self.width)
        .frame(minHeight: inline ? nil : 560, idealHeight: inline ? nil : 660, maxHeight: inline ? .infinity : 760)
        .background(Theme.panel)
        .onAppear { run() }
        .onDisappear { task?.cancel() }
    }

    // MARK: Lancement

    private func run() {
        task?.cancel()
        copied = false
        if store.isDemo {
            // Démonstration et captures : mesures fictives, aucun ping.
            let full = store.diagnose(target, paths: store.pingEnabled ? WifiDiagnosisDemo.paths() : [], state: state)
            result = full
            if !inline { store.record(full, rssi: rssi) }
            return
        }
        let instant = store.diagnose(target, paths: [], state: state)
        result = instant
        guard store.pingEnabled else {
            store.record(instant, rssi: rssi)
            return
        }
        measuring = true
        task = Task { @MainActor in
            let paths = await store.measurePaths(state: state)
            guard !Task.isCancelled else { return }
            let full = store.diagnose(target, paths: paths, state: state)
            result = full
            measuring = false
            store.record(full, rssi: rssi)
        }
    }

    private var rssi: Int? {
        if case .client(let c, _) = target.kind { return store.currentClient(c).rssi }
        return nil
    }

    private var kindLabel: String {
        switch target.kind {
        case .client: return "Client"
        case .ap: return "Borne"
        case .ssid: return "SSID"
        }
    }

    private var kindSymbol: String {
        switch target.kind {
        case .client: return "laptopcomputer.and.iphone"
        case .ap: return "wifi.router"
        case .ssid: return "wifi"
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft)
                Image(systemName: "stethoscope").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accentStrong)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    WifiHeading("Diagnostic Wi-Fi")
                    Label(kindLabel, systemImage: kindSymbol).font(Theme.caption).foregroundStyle(Theme.textSecondary).labelStyle(.titleAndIcon)
                    if !target.site.isEmpty {
                        Text("· \(target.site)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(target.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                if let context = result?.context, !context.isEmpty {
                    Text(context).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let result { WifiVerdictPill(verdict: result.overall, large: true) }
        }
    }

    // MARK: Contenu

    @ViewBuilder private func content(_ r: WifiDiagnosisResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            banner(r)
            if !r.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    WifiHeading("Actions suggérées, dans l’ordre")
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(r.actions.enumerated()), id: \.offset) { index, action in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text("\(index + 1)")
                                    .font(Theme.mono(11, weight: .bold))
                                    .foregroundStyle(Theme.onAccent)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(index == 0 ? Theme.accent : Theme.accent.opacity(0.75)))
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                Text(action).font(Theme.body).foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            let flagged = r.causes.filter { $0.verdict >= .watch }
            if !flagged.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    WifiHeading("Ce qui ne va pas")
                    ForEach(flagged) { cause in causeCard(cause) }
                }
            }
            let oks = r.oks
            if !oks.isEmpty {
                DisclosureGroup(isExpanded: $showOK) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(oks) { cause in compactRow(cause) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Vérifié, sans problème (\(oks.count))").font(Theme.bodySemibold)
                }
            }
            let unchecked = r.unchecked
            if !unchecked.isEmpty {
                DisclosureGroup(isExpanded: $showUnchecked) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(unchecked) { cause in compactRow(cause) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Non vérifié (\(unchecked.count))").font(Theme.bodySemibold).foregroundStyle(Theme.textSecondary)
                }
            }
            // Remarques du moteur (s'il y en a), puis les rappels toujours affichés.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(r.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.isDemo {
                    Label("Démonstration\u{00A0}: lecture et mesures fictives, aucun ping envoyé.", systemImage: "theatermasks")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                Label("Lecture seule\u{00A0}: NetScope propose, le technicien applique. Rien n’est modifié sur la FortiGate.", systemImage: "lock")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func banner(_ r: WifiDiagnosisResult) -> some View {
        let tone = r.overall.tone
        let history = store.history(of: r)
        let previous = history.previous(r.subject.key, before: r.date.addingTimeInterval(-1))
        let recurrence = history.recurrence(r.subject.key)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.overall.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tone.foreground)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.headline).font(Theme.bodySemibold).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                if let primary = r.primary {
                    Text(primary.summary).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
                Text(counts(r)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                if let previous {
                    Label("Diagnostic précédent\u{00A0}: \(Self.relative(previous.date)) — \(previous.overall.label.lowercased())"
                          + (previous.primary.map { " (\(Self.lowerFirst($0.title)))" } ?? ""), systemImage: "clock.arrow.circlepath")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                if let recurrence {
                    Label(recurrence, systemImage: "chart.line.uptrend.xyaxis").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tone.background))
    }

    private func counts(_ r: WifiDiagnosisResult) -> String {
        var parts: [String] = []
        let p = r.problems.count, w = r.watches.count, o = r.oks.count, u = r.unchecked.count
        if p > 0 { parts.append("\(p) problème\(p > 1 ? "s" : "")") }
        if w > 0 { parts.append("\(w) à surveiller") }
        parts.append("\(o) OK")
        if u > 0 { parts.append("\(u) non vérifiée\(u > 1 ? "s" : "")") }
        return parts.joined(separator: " · ") + (r.measured ? " · ping depuis ce Mac" : "")
    }

    private func causeCard(_ cause: WifiCauseResult) -> some View {
        let tone = cause.verdict.tone
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: cause.cause.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.foreground)
                    .frame(width: 16)
                Text(cause.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                WifiVerdictPill(verdict: cause.verdict)
            }
            Text(cause.summary).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
            if !cause.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(cause.evidence, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").font(Theme.small).foregroundStyle(Theme.textTertiary)
                            Text(line).font(Theme.small).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(cause.verdict == .problem ? tone.foreground.opacity(0.45) : Theme.border))
    }

    private func compactRow(_ cause: WifiCauseResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: cause.verdict.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(cause.verdict.tone.foreground)
                .frame(width: 16)
            Text(cause.title).font(.system(size: 12, weight: .semibold)).frame(width: 200, alignment: .leading)
            Text(([cause.summary] + cause.evidence.prefix(1)).joined(separator: " · "))
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $store.pingEnabled) {
                Text("Ping depuis ce Mac (\(Int(WifiDiagnosisStore.pingSeconds))\u{00A0}s)").font(Theme.small)
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .disabled(measuring || store.isDemo)
            .help("Mesure la perte et la latence vers la passerelle, le DNS et 1.1.1.1 depuis ce Mac (pas depuis le client)\u{00A0}: dit si le problème dépasse le Wi-Fi.")
            .onChange(of: store.pingEnabled) { _, on in if on, !store.isDemo { run() } }
            if measuring {
                ProgressView().controlSize(.small)
                Text("Ping en cours…").font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .help("Ping de la passerelle, du DNS et de 1.1.1.1 depuis ce Mac")
            }
            Spacer(minLength: 8)
            Button { run() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.secondary)
                .disabled(measuring)
                .help("Relancer le diagnostic")
            Button(copied ? "Copié" : "Copier") {
                guard let result else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(WifiDiagnosisText.plain(result), forType: .string)
                copied = true
            }
            .buttonStyle(.secondary)
            .disabled(result == nil)
            .help("Copie le diagnostic en texte (verdict, actions, causes et mesures)")
            reportButton
            Button("Fermer") { dismiss() }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var reportButton: some View {
        if let result, store.isReported(result) {
            Button { store.removeFromReport(result) } label: { Label("Dans le rapport", systemImage: "checkmark") }
                .buttonStyle(.secondary)
                .help("Diagnostic retenu pour la section «\u{00A0}Diagnostic Wi-Fi\u{00A0}» du rapport du site. Cliquer pour le retirer.")
        } else {
            Button("Ajouter au rapport du site") { if let result { store.addToReport(result) } }
                .buttonStyle(.secondary)
                .disabled(result == nil || measuring)
                .help("Retient ce diagnostic pour la section «\u{00A0}Diagnostic Wi-Fi\u{00A0}» des Rapports (cochée).")
        }
    }

    static func lowerFirst(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 90 { return "à l’instant" }
        if seconds < 3600 { return "il y a \(Int(seconds / 60))\u{00A0}min" }
        if seconds < 86_400 { return "il y a \(Int(seconds / 3600))\u{00A0}h" }
        let days = Int(seconds / 86_400)
        return days == 1 ? "hier" : "il y a \(days)\u{00A0}jours"
    }
}

// MARK: - Captures

/// Captures (NETSCOPE_WIFI_DIAG) : la feuille dessinée par-dessus Wi-Fi › FortiAP, sous la barre
/// d'outils, comme une feuille de macOS (une vraie feuille ne se capture pas hors écran).
struct WifiDiagnosisSnapshotOverlay: View {
    @ObservedObject private var fortiAP = FortiAPStore.shared

    var body: some View {
        if let target = WifiDiagnosisDemo.snapshotTarget(in: fortiAP.shownOverview) {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Color(nsColor: .shadowColor).opacity(0.18).ignoresSafeArea()
                    WifiDiagnosisSheet(target: target, inline: true, dismiss: {})
                        .frame(height: max(320, geo.size.height - 16))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
                        .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 18, y: 8)
                        .padding(.top, 8)
                }
                .frame(width: geo.size.width)
            }
        }
    }
}
