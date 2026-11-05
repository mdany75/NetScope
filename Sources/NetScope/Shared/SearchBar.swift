import NetScopeCore
import SwiftUI

// Recherche multiple (note 26) : champs de chaque module, étiquettes des critères sous la barre
// d'outils, menu des préfixes et nombre de résultats. Le moteur (SearchQuery) est dans NetScopeCore.

extension Screen {
    /// Champs de recherche du module ; nil si la recherche de la barre d'outils ne filtre rien ici.
    var searchSchema: SearchSchema? {
        switch self {
        case .scanner: return .scanner
        case .carte: return .carte
        case .inventaire: return .inventaire
        case .analyse: return .analyse
        case .surveillance: return .surveillance
        case .acces: return .acces
        case .outils: return .outils
        case .reglages: return .reglages
        case .switchs: return .switchs
        case .wifi: return .wifiEcran
        case .journaux: return .journaux
        default: return nil
        }
    }

    /// Ce que la recherche filtre, pour l'aide : « les appareils du scan ».
    var searchScope: String {
        switch self {
        case .scanner: return "les appareils du scan"
        case .carte: return "les appareils du site dessiné (la carte se centre sur chaque résultat)"
        case .inventaire: return "les fiches de l’inventaire"
        case .analyse: return "les alertes et changements"
        case .surveillance: return "les sondes et le journal des alertes"
        case .acces: return "les connexions enregistrées"
        case .outils: return "les outils et l’historique"
        case .reglages: return "les sections des réglages"
        case .switchs: return "la table MAC du switch affiché"
        case .wifi: return "les réseaux voisins et les tableaux FortiAP"
        case .journaux: return "les messages Syslog, les traps et les journaux de la FortiGate"
        default: return "cet écran"
        }
    }
}

/// Recherche des appareils du Scanner, avec ce que l'app sait en plus du scan.
@MainActor
enum DeviceSearch {
    static func item(_ device: Device, typed: Device? = nil) -> DeviceSearchItem {
        let site = device.switchName.flatMap { SwitchStore.shared.controllerName(forSwitch: $0) }
        let note = DeviceNotesStore.shared.note(for: device)
        let record = InvModel.shared.record(DeviceNotesStore.key(for: device))
        let notes = [note, record?.annotations.notes ?? ""].filter { !$0.isEmpty }
        return DeviceSearchItem(typed ?? device, site: site, siteName: SiteModel.shared.activeSite?.displayName, notes: notes)
    }

    /// Appareils qui correspondent à la requête ; le type comparé est celui affiché (choisi à la main).
    static func filter(_ devices: [Device], _ query: SearchQuery) -> [Device] {
        guard !query.isEmpty else { return devices }
        let typed = InvModel.shared.withManualTypes(devices)
        return zip(devices, typed).compactMap { device, shown in
            query.matches(item(device, typed: shown)) ? device : nil
        }
    }
}

// MARK: - Validation du champ (note 32)

/// ↩︎ ou ⇧↩︎ dans le champ de recherche de la barre d'outils : l'écran passe au résultat suivant
/// ou précédent (Carte du réseau). `serial` change à chaque validation.
struct SearchSubmit: Equatable {
    var screen: Screen?
    var backwards = false
    var serial = 0
}

// MARK: - Nombre de résultats

/// Résultats de la recherche annoncés par l'écran (« 3 appareils », « 2 sondes »).
struct SearchResultsKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

extension View {
    /// Annonce le nombre de résultats de la recherche du module (affiché à côté des étiquettes).
    func searchResults(_ count: Int, _ singular: String, _ plural: String) -> some View {
        preference(key: SearchResultsKey.self, value: ["\(count) \(count > 1 ? plural : singular)"])
    }
}

// MARK: - Barre des critères

/// Étiquettes des critères de la recherche, sous la barre d'outils : une par critère, retirable
/// d'un clic ; menu des préfixes du module, aide et nombre de résultats.
struct SearchTokensBar: View {
    @EnvironmentObject private var state: AppState
    let schema: SearchSchema
    let results: [String]

    var body: some View {
        let query = SearchQuery(state.searchText, schema: schema)
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .help(SearchTokensBar.help(state.screen, schema))
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    // Filtre transmis par un autre écran (Carte, port de switch) : en premier.
                    if let filter = state.navFilters[state.screen] {
                        NavFilterChip(filter: filter) { state.navFilters[state.screen] = nil }
                    }
                    ForEach(query.terms.filter(\.isComplete)) { term in
                        SearchTokenChip(term: term) { state.searchText = query.removing(term) }
                    }
                    if let pending = query.terms.last(where: { !$0.isComplete }) {
                        Text(pending.source)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .help("Préfixe sans valeur\u{00A0}: tapez la valeur cherchée.")
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .layoutPriority(1)
            Spacer(minLength: 4)
            if !query.isEmpty || state.navFilters[state.screen] != nil, !results.isEmpty {
                Text(results.joined(separator: " · "))
                    .font(Theme.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            SearchPrefixMenu(schema: schema)
            Button("Effacer") {
                state.searchText = ""
                state.navFilters[state.screen] = nil
            }
                .buttonStyle(.borderless)
                .font(Theme.small)
                .help("Effacer toute la recherche")
                .fixedSize()
        }
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: 36)
        .background(Theme.appBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// Aide courte au survol.
    static func help(_ screen: Screen, _ schema: SearchSchema) -> String {
        """
        Recherche dans \(screen.searchScope). Mots séparés par des espaces\u{00A0}: tous à la fois.
        préfixe:valeur cherche dans un champ (ex. \(schema.example))\u{00A0}; -mot exclut\u{00A0}; "phrase exacte" entre guillemets.
        Sans casse ni accents\u{00A0}; ip:10.20. ou ip:10.20.0.0/16\u{00A0}; vlan:4 ne trouve pas 40.
        """
    }
}

/// Étiquette d'un critère : préfixe en gras, valeur, bouton × ; un critère exclu est barré en rouge.
struct SearchTokenChip: View {
    let term: SearchTerm
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if term.isNegated {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.critical)
                    .accessibilityLabel("Exclut")
            }
            if let field = term.field {
                Text(field.label + "\u{00A0}:").font(.system(size: 11.5, weight: .semibold))
            }
            Text(term.isPhrase ? "«\u{00A0}\(term.value)\u{00A0}»" : term.value)
                .font(.system(size: 11.5, weight: .medium))
                .strikethrough(term.isNegated, color: Theme.critical.opacity(0.7))
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Theme.hover))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer le critère \(term.label)")
        }
        .foregroundStyle(term.isNegated ? Theme.critical : (term.field == nil ? Theme.neutralText : Theme.accentStrong))
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(Capsule().fill(term.isNegated ? Theme.criticalSoft : (term.field == nil ? Theme.neutralSoft : Theme.accentSoft)))
        .fixedSize()
        .help(term.help)
    }
}

/// Menu des préfixes du module : un clic ajoute « préfixe: » à la recherche ; l'exemple du module
/// remplace la recherche.
struct SearchPrefixMenu: View {
    @EnvironmentObject private var state: AppState
    let schema: SearchSchema
    var compact = false

    var body: some View {
        Menu {
            Section("Chercher dans un champ") {
                ForEach(schema.fields) { field in
                    Button {
                        state.searchText = SearchQuery(state.searchText, schema: schema).inserting(field)
                    } label: {
                        Text("\(field.label) — \(field.sample)")
                    }
                }
            }
            if !schema.example.isEmpty {
                Section("Exemple") {
                    Button(schema.example) { state.searchText = schema.example }
                }
            }
            Section("Syntaxe") {
                Text("Espaces\u{00A0}: tous les mots à la fois")
                Text("-mot ou -préfixe:valeur\u{00A0}: exclut")
                Text("\"phrase exacte\"\u{00A0}: entre guillemets")
            }
        } label: {
            Label("Critères", systemImage: "text.badge.plus")
                .labelStyle(.titleAndIcon)
                .font(Theme.small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Préfixes de recherche de ce module (ex. \(schema.example))")
    }
}

/// Suggestions du champ de recherche de la barre d'outils : les préfixes du module qui
/// commencent par le mot en cours de saisie (tous, quand le champ est vide ou finit par une espace).
struct SearchPrefixSuggestions: View {
    let text: String
    let schema: SearchSchema

    var body: some View {
        let query = SearchQuery(text, schema: schema)
        ForEach(SearchPrefixSuggestions.fields(query)) { field in
            HStack(spacing: 8) {
                Text(field.key + ":").font(Theme.mono(12)).fontWeight(.semibold)
                Text("\(field.label) · ex. \(field.sample)").foregroundStyle(.secondary)
            }
            .searchCompletion(query.inserting(field))
        }
    }

    static func fields(_ query: SearchQuery) -> [SearchAttribute] {
        let text = query.text
        if text.trimmingCharacters(in: .whitespaces).isEmpty || text.hasSuffix(" ") { return query.schema.fields }
        guard let word = query.pendingWord.map(SearchText.fold), !word.isEmpty else { return [] }
        return query.schema.fields.filter { field in
            field.aliases.contains { SearchText.fold($0).hasPrefix(word) && SearchText.fold($0) != word }
        }
    }
}
