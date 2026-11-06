import NetScopeCore
import SwiftUI

/// Écran Appareil sans appareil choisi : « Ouvrir une fiche » par IP, nom ou MAC, avec suggestions
/// parmi les appareils connus, saisie à la main d'un appareil inconnu et fiches consultées récemment.
struct DeviceLookupPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = DeviceLookupModel.shared
    // Observés pour relire les suggestions quand le site actif ou l'inventaire change.
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var inventory = InvModel.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                searchPanel
                if model.formShown {
                    DeviceManualForm(model: model)
                        .transition(.opacity)
                }
                recentsPanel
            }
            .frame(maxWidth: 780, alignment: .topLeading)
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            model.refreshCandidates(state)
            if !model.formShown { fieldFocused = true }
        }
        .onChange(of: DeviceLookupModel.signature(state)) { _, _ in model.refreshCandidates(state) }
        .onChange(of: model.searchFocusRequest) { _, _ in fieldFocused = true }
    }

    // MARK: En-tête

    private var intro: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.accentSoft)
                Image(systemName: "rectangle.and.text.magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ouvrir une fiche").font(Theme.screenTitle).foregroundStyle(Theme.text)
                Text("Aucun appareil sélectionné. Tapez une adresse IP, un nom ou une adresse MAC\u{00A0}: un appareil connu s’ouvre aussitôt, un appareil inconnu peut être saisi à la main.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Recherche et suggestions

    private var searchPanel: some View {
        let found = model.suggestions
        let current = model.highlightIndex(found)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                field(found)
                entryLine(found)
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(Theme.small).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            if !found.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, match in
                        Button { model.open(match.candidate, state: state) } label: {
                            DeviceSuggestionRow(match: match, highlighted: index == current)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in if inside, current >= 0 { model.highlighted = index } }
                        .help("Ouvrir la fiche de \(match.candidate.displayName)")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            footer(found)
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func field(_ found: [DeviceLookupMatch]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
            TextField("Ouvrir une fiche", text: $model.query,
                      prompt: Text("IP, nom, MAC ou fabricant — ex. 10.182.122.50, imprimante, 94:dd:f8"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .onSubmit { model.submit(state) }
                .onKeyPress(.downArrow) { model.move(1, count: found.count); return .handled }
                .onKeyPress(.upArrow) { model.move(-1, count: found.count); return .handled }
                .onKeyPress(.escape) {
                    guard !model.query.isEmpty else { return .ignored }
                    model.query = ""
                    return .handled
                }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Effacer")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius + 2).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius + 2)
            .strokeBorder(fieldFocused ? Theme.accent : Theme.borderStrong, lineWidth: fieldFocused ? 2 : 1))
    }

    /// Ce que NetScope reconnaît dans la saisie.
    @ViewBuilder private func entryLine(_ found: [DeviceLookupMatch]) -> some View {
        let entry = model.entry
        switch entry {
        case .empty:
            Text("Suggestions parmi les résultats du Scanner (site actif et autres sites), l’Inventaire et vos saisies\u{00A0}; ↑ ↓ pour choisir, Entrée pour ouvrir.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .ip, .hostname, .mac:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text(recognized(entry)).foregroundStyle(Theme.textSecondary)
            }
            .font(Theme.small)
        case .ambiguous(let mac, let name):
            VStack(alignment: .leading, spacing: 6) {
                Label(entry.summary ?? "", systemImage: "questionmark.circle")
                    .font(Theme.small).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("C’est une adresse MAC") { model.query = mac.formatted(.upperColon) }.buttonStyle(.secondary)
                    Button("C’est un nom d’hôte") { model.showForm(prefilledFrom: .hostname(name)) }.buttonStyle(.secondary)
                }
            }
        case .invalid(let reason):
            // Avec des suggestions, la saisie est un morceau cherché : simple indication.
            Label(found.isEmpty ? reason : "\(reason) — cherché parmi les appareils connus", systemImage: found.isEmpty ? "exclamationmark.triangle" : "info.circle")
                .font(Theme.small)
                .foregroundStyle(found.isEmpty ? Theme.warning : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func recognized(_ entry: DeviceEntry) -> String {
        switch entry {
        case .mac(let mac):
            return "Adresse MAC \(mac.formatted(.upperColon)) · \(OUIDatabase.builtIn.label(for: mac))"
        case .hostname:
            return "Nom d’hôte · résolu seulement si vous le demandez"
        default:
            return entry.summary ?? ""
        }
    }

    @ViewBuilder private func footer(_ found: [DeviceLookupMatch]) -> some View {
        let entry = model.entry
        let exact = found.first?.isExact == true
        // Sans suggestion, ou avec une saisie qu'on peut ouvrir à la main (IP, MAC, nom d'hôte).
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty, !exact, found.isEmpty || entry.isUsable {
            let formFirst = found.isEmpty || model.prefersForm(found)
            HStack(spacing: 10) {
                Text(found.isEmpty ? "Aucun appareil connu ne correspond."
                     : formFirst ? "Aucun appareil connu à cette adresse\u{00A0}: Entrée pour la saisir, ↓ pour les suggestions."
                     : "Pas dans la liste\u{00A0}?")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if entry.isUsable {
                    let label = "Saisir «\u{00A0}\(model.query.trimmingCharacters(in: .whitespaces))\u{00A0}» à la main…"
                    if formFirst {
                        Button(label) { model.showForm(prefilledFrom: entry) }.buttonStyle(.primary)
                    } else {
                        Button(label) { model.showForm(prefilledFrom: entry) }.buttonStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    // MARK: Consultés récemment

    private var recentsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Consultés récemment") {
                    HStack(spacing: 8) {
                        if !model.formShown {
                            Button { model.showForm() } label: { Label("Saisir un appareil à la main…", systemImage: "square.and.pencil") }
                                .buttonStyle(.secondary)
                        }
                        Button { state.open(.scanner) } label: { Label("Ouvrir le Scanner", systemImage: Screen.scanner.symbol) }
                            .buttonStyle(.secondary)
                    }
                }
                let recents = state.siteRecentDeviceViews
                if recents.isEmpty {
                    Text("Les fiches que vous ouvrez apparaîtront ici.")
                        .font(Theme.small).foregroundStyle(Theme.textTertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(recents) { recent in
                            Button { model.open(recent, state: state) } label: {
                                DeviceRecentRow(recent: recent)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Ouvrir la fiche de \(recent.name)")
                        }
                    }
                }
            }
        }
    }
}

/// Une suggestion : type, nom, IP, MAC, fabricant, origine et état.
struct DeviceSuggestionRow: View {
    let match: DeviceLookupMatch
    let highlighted: Bool

    private var candidate: DeviceLookupCandidate { match.candidate }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(highlighted ? Theme.panel : Theme.neutralSoft)
                Image(systemName: candidate.type.toolSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(highlighted ? Theme.accent : Theme.textSecondary)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.displayName).font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1)
                    if let host = candidate.hostname, host != candidate.displayName {
                        Text(host).font(Theme.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                HStack(spacing: 12) {
                    if let ip = candidate.ip { value(ip.description, matched: match.field == .ip) }
                    if let mac = candidate.mac { value(mac.formatted(.upperColon), matched: match.field == .mac) }
                    if let vendor = candidate.vendor ?? candidate.mac.map({ OUIDatabase.builtIn.label(for: $0) }) {
                        Text(vendor).font(Theme.small)
                            .foregroundStyle(match.field == .vendor ? Theme.text : Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            originChip
            if let online = candidate.isOnline, candidate.origin == .scanner || candidate.origin == .manual {
                StatusDot(online: online, size: 7)
                    .help(online ? "En ligne au dernier scan" : "Hors ligne au dernier scan")
            }
            Image(systemName: highlighted ? "return" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(highlighted ? Theme.accent : Theme.textTertiary)
                .frame(width: 14)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(highlighted ? Theme.accentSoft : Color.clear))
    }

    private func value(_ text: String, matched: Bool) -> some View {
        Text(text)
            .font(Theme.mono(12, weight: matched ? .semibold : .regular))
            .foregroundStyle(matched ? Theme.text : Theme.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder private var originChip: some View {
        switch candidate.origin {
        case .scanner: Chip(text: "Scanner", tone: .accent, systemImage: Screen.scanner.symbol)
        case .manual: Chip(text: "Saisi à la main", tone: .warning, systemImage: "hand.point.up.left")
        case .inventory: Chip(text: "Inventaire", tone: .neutral, systemImage: Screen.inventaire.symbol)
        case .otherSite: Chip(text: "Site «\u{00A0}\(candidate.siteName ?? "autre")\u{00A0}»", tone: .neutral, systemImage: "building.2")
        }
    }
}

/// Une fiche consultée récemment.
struct DeviceRecentRow: View {
    @EnvironmentObject private var state: AppState
    let recent: DeviceRecentView
    /// Faux (Boîte à outils › « Ressources d'un poste ») : aucune pastille pour un poste ni dans le
    /// Scanner ni saisi à la main (adresse tapée dans l'outil, jamais passée par le Scanner).
    var marksMissing = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recent.type.toolSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.neutralSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(recent.name).font(Theme.bodyMedium).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 8) {
                    Text(recent.ip.description).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                    Text(ToolText.relative(recent.viewed)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            status
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
    }

    /// État actuel : dans le Scanner (en ligne ou non), saisi à la main, ou plus dans les résultats.
    @ViewBuilder private var status: some View {
        if let device = scanned {
            StatusDot(online: device.isOnline, size: 7).help(device.isOnline ? "En ligne" : "Hors ligne")
        } else if let entry = state.manualEntry(forID: recent.ip.description) {
            if entry.isTyped {
                Chip(text: "Saisi à la main", tone: .warning)
            } else {
                Chip(text: "Hors Scanner", tone: .neutral)
            }
        } else if marksMissing {
            Chip(text: "Plus dans les résultats", tone: .neutral).opacity(0.7)
        }
    }

    private var scanned: Device? {
        if let mac = recent.mac, let device = state.devices.first(where: { $0.mac == mac }) { return device }
        return state.devices.first { $0.ip == recent.ip && (recent.mac == nil || $0.mac == nil) }
    }
}
