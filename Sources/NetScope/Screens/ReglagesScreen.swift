import NetScopeCore
import SwiftUI

/// Écran `Screen.reglages` (croquis docs/croquis/Reglages.dc.html) : colonne des sections à
/// gauche, contenu de la section à droite. Les réglages s'enregistrent dès qu'ils changent.
struct ReglagesScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var navigation = RegNavigation.shared
    @ObservedObject private var updates = UpdController.shared
    @State private var query = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // La colonne des sections défile elle-même en petite fenêtre (pas de défilement global).
            ScrollView {
                sectionColumn
                    .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 248)
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 20)
            }
            .id(navigation.section)
        }
        .padding(.top, 16)
        .padding(.horizontal, Theme.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            updates.attach(state)
            // Arrivée par la pastille « Mise à jour disponible » : on montre la mise à jour.
            if !navigation.didPromoteUpdates, state.updateAvailable != nil {
                navigation.section = .majs
            }
            navigation.didPromoteUpdates = true
        }
        .screenToolbar {
            HStack(spacing: 6) {
                Circle().fill(Theme.success).frame(width: 8, height: 8)
                Text("Réglages enregistrés automatiquement")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.success)
            }
            // Marge avant le champ de recherche de la barre d'outils.
            .padding(.trailing, 10)
            .help("Chaque modification est enregistrée aussitôt ; les secrets vont dans le Trousseau macOS.")
        }
    }

    // MARK: Colonne des sections

    private var visibleSections: [RegSection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return RegSection.allCases }
        return RegSection.allCases.filter { ($0.label + " " + $0.keywords).lowercased().contains(needle) }
    }

    private var sectionColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                TextField("", text: $query, prompt: Text("Rechercher un réglage").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.small)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .padding(.bottom, 6)

            ForEach(visibleSections) { section in
                sectionButton(section)
            }
            if visibleSections.isEmpty {
                Text("Aucun réglage ne correspond à « \(query) ».")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(10)
            }
            Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 6)
            Text("Réglages stockés dans les préférences de NetScope. Les secrets restent dans le Trousseau macOS.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func sectionButton(_ section: RegSection) -> some View {
        let selected = navigation.section == section
        return Button {
            navigation.section = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.accentStrong : Theme.textSecondary)
                // Une seule ligne pour toutes les sections : hauteur uniforme de la liste.
                Text(section.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.accentStrong : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                note(for: section)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(selected ? Theme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func note(for section: RegSection) -> some View {
        switch section {
        case .sites:
            Text("\(state.ranges.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
        case .profils:
            Text("\(ScanProfile.allCases.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
        case .interface:
            if let name = state.activeInterface?.name {
                Text(name).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
        case .majs:
            if state.updateAvailable != nil { CountBadge(count: 1) }
        case .switchs:
            Text("\(SwitchStore.shared.hosts.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
        case .export, .raccourcis:
            // Petite pastille « bientôt » en police réduite : le libellé de la section reste sur une ligne.
            Text("bientôt")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Theme.neutralSoft))
                .help("Section pas encore disponible dans cette version")
        default:
            EmptyView()
        }
    }

    // MARK: Contenu

    @ViewBuilder private var content: some View {
        switch navigation.section {
        case .general: RegGeneralSection()
        case .sites: RegSitesSection()
        case .profils: RegProfilesSection()
        case .identifiants: RegCredentialsSection()
        case .interface: RegInterfaceSection()
        case .majs: RegUpdatesSection()
        case .apropos: RegAboutSection()
        case .switchs: RegSwitchesSection()
        case .notifications:
            RegPanel(title: navigation.section.label) {
                RegNotice(text: "Les notifications macOS, le son, le courriel et le webhook se règlent sonde par sonde dans Surveillance (Actions d’alerte de chaque sonde).", tone: .accent) {
                    Button("Ouvrir Surveillance") { state.open(.surveillance) }
                        .buttonStyle(.secondary)
                }
            }
        case .export, .raccourcis:
            RegPanel(title: navigation.section.label) {
                RegNotice("Section prévue au croquis, pas encore disponible dans cette version de NetScope.", tone: .neutral)
            }
        }
    }
}
