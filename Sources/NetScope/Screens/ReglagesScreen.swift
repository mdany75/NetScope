import NetScopeCore
import SwiftUI

/// Écran `Screen.reglages` (croquis docs/croquis/Reglages.dc.html) : colonne des sections à
/// gauche, contenu de la section à droite. Les réglages s'enregistrent dès qu'ils changent.
struct ReglagesScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var navigation = RegNavigation.shared
    /// Nombre de sites de la liste des sections (créés, importés, supprimés).
    @ObservedObject private var siteModel = SiteModel.shared
    @ObservedObject private var updates = UpdController.shared
    // Pastilles des sections Notifications (autorisation refusée) et Raccourcis (conflits).
    @ObservedObject private var notifications = RegNotifStore.shared
    @ObservedObject private var shortcuts = RegShortcutStore.shared
    /// Pastille « Export et sauvegarde » : nombre de sauvegardes, suivi après chaque sauvegarde ou rotation.
    @ObservedObject private var backupStore = RegBackupController.shared
    /// Pastille « Journal et diagnostic » : erreurs récentes pas encore consultées (note 35).
    @ObservedObject private var diagnostics = RegDiagnosticController.shared
    /// Pastille « Synchronisation » : conflits et suppressions à confirmer (note 86).
    @ObservedObject private var sync = RegSyncController.shared
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
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 20)
                }
                .onAppear { scrollToFocus(proxy) }
                .onChange(of: navigation.focus) { _, _ in scrollToFocus(proxy) }
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

    /// Défile jusqu'au panneau demandé (par exemple « Actions sur les ports »), une fois la page posée.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let focus = navigation.focus else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(focus, anchor: .top) }
            navigation.focus = nil
        }
    }

    // MARK: Colonne des sections

    /// Sections retenues par la recherche de la colonne et celle de la barre d'outils (note 26 :
    /// moteur commun, `section:alertes`, un mot seul lit le titre et les mots-clés comme avant).
    private var visibleSections: [RegSection] {
        let local = SearchQuery(query, schema: .reglages)
        let global = state.searchQuery(for: .reglages)
        guard !local.isEmpty || !global.isEmpty else { return RegSection.ordered }
        return RegSection.ordered.filter { section in
            let item = SearchDocument(["section": [section.label]], freeText: [section.label + " " + section.keywords])
            return local.matches(item) && global.matches(item)
        }
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
                Text(query.isEmpty ? "Aucun réglage ne correspond à la recherche." : "Aucun réglage ne correspond à «\u{00A0}\(query)\u{00A0}».")
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
        .searchResults(visibleSections.count, "section", "sections")
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
            Text("\(siteModel.sites.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
        case .profils:
            Text("\(ScanProfile.allCases.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
        case .interface:
            if let name = state.activeInterface?.name {
                Text(name).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
        case .majs:
            if state.updateAvailable != nil { CountBadge(count: 1) }
        case .switchs:
            Text("\(SwitchStore.shared.allHosts.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
        case .raccourcis:
            let conflicts = RegShortcutStore.shared.conflicts.count
            if conflicts > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
                    .help("\(conflicts) raccourci\(conflicts > 1 ? "s" : "") en conflit")
            }
        case .notifications:
            if RegNotifStore.shared.authorization == .denied {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.critical)
                    .help("Notifications refusées par macOS")
            }
        case .diagnostic:
            if diagnostics.unseenErrorCount > 0 {
                CountBadge(count: diagnostics.unseenErrorCount, color: Theme.criticalBadge)
                    .help("Erreurs récentes pas encore consultées")
            }
        case .synchro:
            if sync.attentionCount > 0 {
                CountBadge(count: sync.attentionCount, color: Theme.warningDot)
                    .help("Conflits et suppressions venues d’un autre Mac à voir")
            } else if sync.enabled {
                Image(systemName: "checkmark.icloud").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .help("Synchronisation activée")
            }
        case .export:
            if !backupStore.backups.isEmpty {
                Text("\(backupStore.backups.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
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
        case .rustdesk: RegRustDeskSection()
        case .majs: RegUpdatesSection()
        case .apropos: RegAboutSection()
        case .switchs: RegSwitchesSection()
        case .alertes: RegAlertsSection()
        case .notifications: RegNotificationsSection()
        case .raccourcis: RegShortcutsSection()
        case .diagnostic: RegDiagnosticSection()
        case .export:
            // Note 56 : configuration (export, import) après les sauvegardes (en premier pour les
            // captures « NETSCOPE_REGLAGES_SECTION=configuration »).
            VStack(alignment: .leading, spacing: 14) {
                if ConfigSyncDemo.focusOnConfiguration {
                    RegConfigSection()
                    RegBackupSection()
                } else {
                    RegBackupSection()
                    RegConfigSection()
                }
            }
        case .synchro:
            // Note 86 : tableau de bord de la synchronisation entre les Mac.
            RegSyncSection()
        }
    }
}
