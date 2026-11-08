import Foundation
import NetScopeCore
import SwiftUI

// Boîte à outils › « Ressources d'un poste » : l'onglet Ressources de la fiche (processeur,
// mémoire, trafic par SNMP, ou ce Mac en lecture locale), ouvert directement par IP, nom ou MAC,
// sans passer par le Scanner et la fiche. Mêmes suggestions que « Ouvrir une fiche » (appareils
// connus), mêmes identifiants SNMP (utilisateur v3 du site, sinon communauté v2c).
//
// Réseau : l'interrogation SNMP ne part qu'à l'ouverture d'un poste par l'utilisateur (Entrée,
// clic sur une suggestion ou un poste récent) ; un nom inconnu n'est résolu (DNS) que sur Entrée.
// En démonstration et pendant les captures, rien n'est envoyé (données de ResourceDemo).

/// Poste dont les ressources sont affichées.
struct HostResourcesHost: Equatable {
    var device: Device
    /// Appareil connu d'où il vient (pour « Ouvrir la fiche complète ») ; nil : adresse tapée.
    var candidate: DeviceLookupCandidate?
}

@MainActor
final class HostResourcesModel: ObservableObject {
    static let shared = HostResourcesModel()

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            highlighted = -1
            notice = nil
        }
    }
    /// Suggestion choisie aux flèches (-1 : aucune, Entrée lit la saisie).
    @Published var highlighted = -1
    @Published private(set) var host: HostResourcesHost?
    /// Derniers postes consultés par cet outil (le plus récent d'abord).
    @Published private(set) var recents: [DeviceRecentView] = []
    @Published var notice: String?
    @Published private(set) var isResolving = false
    /// Incrémenté pour rendre le focus au champ (observé par la vue).
    @Published private(set) var focusRequest = 0

    /// Démonstration ou capture : rien n'est lu ni écrit sur le disque, rien sur le réseau.
    let isEphemeral: Bool
    private var resolveTask: Task<Void, Never>?
    private var preparedDemo = false
    private static let recentsKey = "NetScope.outils.ressources.recents"

    private init() {
        let arguments = CommandLine.arguments
        isEphemeral = arguments.contains("--demo") || arguments.contains("--snapshot")
        if !isEphemeral, let data = UserDefaults.standard.data(forKey: Self.recentsKey),
           let saved = try? JSONDecoder().decode([DeviceRecentView].self, from: data) {
            recents = saved
        }
    }

    /// Commande équivalente (en-tête de l'outil).
    var command: String {
        guard let host else { return "snmpwalk <poste> HOST-RESOURCES-MIB · IF-MIB" }
        let ip = host.device.ip.description
        if let user = SNMPAccessVault.shared.v3(for: ip)?.user {
            return "snmpwalk -v3 -u \(user) \(ip) HOST-RESOURCES-MIB · IF-MIB"
        }
        return "snmpwalk -v2c \(ip) HOST-RESOURCES-MIB · IF-MIB"
    }

    // MARK: Appareils connus (les mêmes que « Ouvrir une fiche »)

    /// Appareils connus tels que lus en dernier (la vue les relit à l'apparition et quand les
    /// résultats changent) : rien n'est publié pendant le calcul de la vue.
    var candidates: [DeviceLookupCandidate] { DeviceLookupModel.shared.candidates }

    /// Hors du calcul de la vue (Entrée, clic) : relit les appareils connus s'ils ont changé.
    private func refreshedCandidates(_ state: AppState) -> [DeviceLookupCandidate] {
        DeviceLookupModel.shared.refreshCandidates(state)
        return candidates
    }

    var suggestions: [DeviceLookupMatch] {
        DeviceLookup.suggestions(for: query, in: candidates, limit: 6)
    }

    func move(_ offset: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = min(max(0, highlighted + offset), count - 1)
    }

    // MARK: Ouvrir un poste

    /// Entrée : la suggestion choisie aux flèches, sinon l'appareil connu identique ou l'adresse
    /// tapée ; un nom inconnu est résolu (DNS) seulement si aucune suggestion ne lui correspond.
    func submit(_ state: AppState) {
        let list = refreshedCandidates(state)
        let found = DeviceLookup.suggestions(for: query, in: list, limit: 6)
        if found.indices.contains(highlighted) {
            open(found[highlighted].candidate, state: state)
            return
        }
        switch DeviceLookup.target(for: query, in: list) {
        case .empty:
            return
        case .known(let candidate):
            open(candidate, state: state)
        case .address(let ip):
            open(address: ip, state: state)
        case .hostname(let name):
            if let first = found.first { open(first.candidate, state: state) } else { resolve(name, state: state) }
        case .unknownMAC(let mac):
            notice = "Aucune adresse IP connue pour \(mac.formatted(.upperColon))\u{00A0}: tapez l’adresse IP du poste, ou lancez un scan."
        case .invalid(let reason):
            if let first = found.first { open(first.candidate, state: state) } else { notice = reason }
        }
    }

    /// Ouvre un appareil connu (suggestion, appareil identique ou poste récent).
    func open(_ candidate: DeviceLookupCandidate, state: AppState) {
        guard let ip = candidate.ip else {
            notice = "«\u{00A0}\(candidate.displayName)\u{00A0}» n’a pas d’adresse IP connue\u{00A0}: tapez son adresse."
            return
        }
        let device: Device
        if candidate.origin == .scanner || candidate.origin == .manual, let shown = state.shownDevice(withID: ip.description) {
            // Appareil du Scanner (ou saisi) tel que la fiche le montre : type, agent SNMP vu au scan.
            device = candidate.origin == .scanner ? InvModel.shared.withManualTypes([shown])[0] : shown
        } else {
            device = Device(ip: ip, mac: candidate.mac, vendor: candidate.vendor, hostname: candidate.hostname,
                            customName: candidate.name, isOnline: candidate.isOnline ?? true,
                            lastSeen: candidate.lastSeen ?? Date(), deviceType: candidate.type)
        }
        show(HostResourcesHost(device: device, candidate: candidate))
    }

    /// Ouvre une adresse : l'appareil connu à cette adresse s'il y en a un, sinon l'adresse seule.
    func open(address ip: IPv4Address, state: AppState) {
        if let known = refreshedCandidates(state).first(where: { $0.ip == ip && $0.siteKey == nil }) {
            open(known, state: state)
            return
        }
        show(HostResourcesHost(device: Device(ip: ip, deviceType: .inconnu), candidate: nil))
    }

    /// Rouvre un poste consulté récemment (appareil connu de même MAC, sinon de même IP).
    func open(_ recent: DeviceRecentView, state: AppState) {
        let list = refreshedCandidates(state)
        if let mac = recent.mac, let known = list.first(where: { $0.mac == mac && $0.ip != nil && $0.siteKey == nil }) {
            open(known, state: state)
        } else {
            open(address: recent.ip, state: state)
        }
    }

    private func show(_ host: HostResourcesHost) {
        resolveTask?.cancel()
        isResolving = false
        self.host = host
        query = ""
        notice = nil
        remember(host.device)
    }

    /// « Changer de poste » : retour au champ et aux postes récents.
    func close() {
        host = nil
        query = ""
        notice = nil
        focusRequest += 1
    }

    /// Résout un nom d'hôte (sur Entrée seulement), puis ouvre l'adresse trouvée.
    private func resolve(_ name: String, state: AppState) {
        guard !isEphemeral else {
            notice = "Démonstration\u{00A0}: aucune requête DNS n’est envoyée. Tapez une adresse IP ou choisissez un appareil connu."
            return
        }
        let typed = query
        isResolving = true
        notice = nil
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            let result: Result<IPv4Address, Error>
            do { result = .success(try await PingResolver.resolveAsync(name)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.isResolving = false
            guard self.query == typed else { return }
            switch result {
            case .success(let address):
                self.open(address: address, state: state)
            case .failure(let error):
                self.notice = "«\u{00A0}\(name)\u{00A0}» introuvable\u{00A0}: "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: Postes récents

    private func remember(_ device: Device, at date: Date = Date()) {
        recents = DeviceRecents.record(DeviceRecentView(device: device, viewed: date), in: recents)
        guard !isEphemeral, let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recents = []
        guard !isEphemeral else { return }
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    // MARK: « Ouvrir la fiche complète »

    /// Fiche Appareil du poste, sur l'onglet Ressources ; une adresse inconnue ouvre le formulaire
    /// « Saisir un appareil à la main » prérempli (rien n'est ajouté sans confirmation).
    func openFullSheet(state: AppState) {
        guard let host else { return }
        DeviceSession.shared.tab = .ressources
        let lookup = DeviceLookupModel.shared
        if let candidate = host.candidate {
            lookup.notice = nil
            lookup.open(candidate, state: state)
            // Rien d'ouvert (IP prise dans le Scanner du site actif, fiche d'inventaire disparue) :
            // l'avis s'affiche ici plutôt que sur le panneau Appareil, invisible depuis l'outil.
            if state.screen == .outils {
                notice = lookup.notice
                    ?? "La fiche de «\u{00A0}\(candidate.displayName)\u{00A0}» n’a pas pu être ouverte\u{00A0}: l’appareil n’est plus connu."
                lookup.notice = nil
            }
        } else if state.shownDevice(withID: host.device.id) != nil {
            state.showDevice(host.device.id)
        } else {
            lookup.showForm(prefilledFrom: .ip(host.device.ip))
            // Pas closeDevice() : l'appareil choisi dans le Scanner n'a pas été consulté ici.
            if state.selectedDeviceID != nil { state.openEmptyDevicePanel() } else { state.open(.appareil) }
        }
    }

    // MARK: Démonstration

    /// Postes récents de la démonstration ; captures : NETSCOPE_RESSOURCES_POSTE=10.10.0.10 ouvre
    /// ce poste, NETSCOPE_RESSOURCES_SAISIE="srv" remplit le champ (suggestions).
    func prepareDemo(_ state: AppState) {
        guard Launcher.isDemo, !preparedDemo else { return }
        preparedDemo = true
        let now = Date()
        for (ip, minutes) in [("10.182.122.111", 240.0), ("10.182.122.2", 95), ("10.182.122.117", 30)] {
            if let device = state.device(withID: ip) { remember(device, at: now.addingTimeInterval(-minutes * 60)) }
        }
        guard CommandLine.arguments.contains("--snapshot") else { return }
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["NETSCOPE_RESSOURCES_POSTE"], let ip = IPv4Address(raw) {
            open(address: ip, state: state)
            // Heure des captures : « il y a 3 min » plutôt que l'heure du lancement.
            if var first = recents.first { first.viewed = now.addingTimeInterval(-3 * 60); recents[0] = first }
        }
        if let text = environment["NETSCOPE_RESSOURCES_SAISIE"] { query = text }
    }
}

/// Outil « Ressources d'un poste ».
struct HostResourcesView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = HostResourcesModel.shared
    @ObservedObject var store: ToolStore
    // Observés pour relire les suggestions quand le site actif ou l'inventaire change.
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var inventory = InvModel.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let found = model.query.isEmpty ? [] : model.suggestions
        VStack(alignment: .leading, spacing: 14) {
            search(found)
            if let host = model.host {
                hostBar(host)
                // L'onglet Ressources de la fiche, tel quel (identité : un relevé par poste).
                DeviceResourcesTab(device: host.device, startsOnOpen: !model.isEphemeral)
                    .id(host.device.id)
            } else {
                recentsPanel
            }
        }
        .onAppear {
            DeviceLookupModel.shared.refreshCandidates(state)
            model.prepareDemo(state)
            if model.host == nil { fieldFocused = true }
        }
        .onChange(of: model.focusRequest) { _, _ in fieldFocused = true }
        .onChange(of: DeviceLookupModel.signature(state)) { _, _ in DeviceLookupModel.shared.refreshCandidates(state) }
    }

    // MARK: Champ et suggestions

    private func search(_ found: [DeviceLookupMatch]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: model.host == nil ? "Poste à interroger" : "Autre poste") {
                    field(found)
                }
                Button(model.isResolving ? "Résolution…" : "Afficher les ressources") { model.submit(state) }
                    .buttonStyle(.primary)
                    .disabled(model.isResolving || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(Theme.small).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !found.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, match in
                        Button { model.open(match.candidate, state: state) } label: {
                            DeviceSuggestionRow(match: match, highlighted: index == model.highlighted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Afficher les ressources de \(match.candidate.displayName)")
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            }
        }
    }

    private func field(_ found: [DeviceLookupMatch]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            TextField("Poste à interroger", text: $model.query,
                      prompt: Text("IP, nom ou MAC — ex. 10.10.0.10, SRV-AD-01, poste compta"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit { model.submit(state) }
                .onKeyPress(.downArrow) { model.move(1, count: found.count); return .handled }
                .onKeyPress(.upArrow) { model.move(-1, count: found.count); return .handled }
                .onKeyPress(.escape) {
                    guard !model.query.isEmpty else { return .ignored }
                    model.query = ""
                    return .handled
                }
            if model.isResolving { ProgressView().controlSize(.small) }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Effacer")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.controlHeight + 4)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
            .strokeBorder(fieldFocused ? Theme.accent : Theme.borderStrong, lineWidth: fieldFocused ? 2 : 1))
    }

    // MARK: Poste ouvert

    private func hostBar(_ host: HostResourcesHost) -> some View {
        let device = host.device
        return VStack(alignment: .leading, spacing: 10) {
            identity(host)
            ActionRow { hostActions }
            HStack(spacing: 6) {
                Image(systemName: "key").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Text(credentials(for: device))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Identifiants…") {
                    RegNavigation.shared.section = .identifiants
                    state.open(.reglages)
                }
                .buttonStyle(.secondary)
                .controlSize(.small)
                .help("Réglages › Identifiants\u{00A0}: communauté SNMP v2c et utilisateurs SNMP v3 par site")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func identity(_ host: HostResourcesHost) -> some View {
        let device = host.device
        return HStack(spacing: 10) {
            Image(systemName: device.deviceType.toolSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 10) {
                    Text(device.ip.description).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    if let mac = device.mac {
                        Text(mac.formatted(.upperColon)).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(origin(host)).font(Theme.small).foregroundStyle(Theme.textTertiary)
                }
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var hostActions: some View {
        Button { model.openFullSheet(state: state) } label: {
            Label("Ouvrir la fiche complète", systemImage: Screen.appareil.symbol)
        }
        .buttonStyle(.secondary)
        .help("Ouvrir la fiche Appareil de ce poste, sur l’onglet Ressources")
        Button { model.close() } label: {
            Label("Changer de poste", systemImage: "xmark.circle")
        }
        .buttonStyle(.secondary)
        .help("Fermer ce poste et revenir aux postes récents")
    }

    private func origin(_ host: HostResourcesHost) -> String {
        guard let candidate = host.candidate else { return "Adresse tapée" }
        switch candidate.origin {
        case .scanner: return "Scanner"
        case .manual: return "Saisi à la main"
        case .inventory: return "Inventaire"
        case .otherSite: return "Site «\u{00A0}\(candidate.siteName ?? "autre")\u{00A0}»"
        }
    }

    /// Identifiants essayés, comme dans la fiche : utilisateur SNMP v3 du site, sinon communauté v2c.
    private func credentials(for device: Device) -> String {
        if DeviceResourcesTab.isThisMac(device, state: state) {
            return "Ce Mac\u{00A0}: lecture locale, sans SNMP."
        }
        let vault = SNMPAccessVault.shared
        if let user = vault.v3(for: device.ip)?.user {
            let site = vault.site(for: device.ip).map { " du site «\u{00A0}\($0.displayName)\u{00A0}»" } ?? " de tous les sites"
            return "Identifiants\u{00A0}: utilisateur SNMP v3 «\u{00A0}\(user)\u{00A0}»\(site), sinon communauté v2c (lecture seule)."
        }
        return "Identifiants\u{00A0}: communauté SNMP v2c (lecture seule)\u{00A0}; aucun utilisateur SNMP v3 pour ce site."
    }

    // MARK: Postes récents

    private var recentsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ToolFieldLabel("Postes consultés récemment")
                Spacer()
                if !model.recents.isEmpty {
                    Button("Effacer") { model.clearRecents() }
                        .buttonStyle(.secondary).controlSize(.small)
                }
            }
            if model.recents.isEmpty {
                Text("Tapez l’adresse IP, le nom ou la MAC d’un poste, d’un serveur, d’un switch ou d’une imprimante\u{00A0}: ses ressources s’affichent ici, sans ouvrir sa fiche\u{00A0}; les postes consultés seront gardés dans cette liste.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.recents) { recent in
                        Button { model.open(recent, state: state) } label: {
                            DeviceRecentRow(recent: recent, marksMissing: false).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Afficher les ressources de \(recent.name)")
                    }
                }
            }
            Text("Lecture seule par SNMP (processeur, mémoire, trafic par interface), comme l’onglet Ressources de la fiche\u{00A0}; rien n’est interrogé avant que vous ouvriez un poste.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
