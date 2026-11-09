import NetScopeCore
import SwiftUI

/// Réglages › Identifiants : SNMP v2c (communauté) et SNMP v3 (utilisateur, authentification,
/// confidentialité), enregistrés dans le Trousseau macOS. Les secrets ne sont jamais réaffichés.
/// Note 59 : l'utilisateur v3 peut être propre à un site (« S'applique à ») ; sinon celui de tous
/// les sites sert. SNMP v3 passe d'abord partout, la communauté sert de repli.
struct RegCredentialsSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var tester = RegSNMPTester.shared
    @ObservedObject private var remote = RegRemoteCredentialStore.shared
    @ObservedObject private var vault = SNMPAccessVault.shared
    @ObservedObject private var sites = SiteModel.shared
    @State private var draft = RegSNMPCredentials()
    @State private var saved: RegSNMPCredentials?
    /// Site dont on règle l'utilisateur v3 (nil : tous les sites).
    @State private var scope: UUID?
    /// Utilisateur v3 enregistré pour ce site.
    @State private var siteSaved: RegSNMPCredentials?
    @State private var loaded = false
    @State private var message: (text: String, tone: Tone)?

    private var isDirty: Bool { draft != mergedDraft() }

    /// Source des champs v3 affichés : le site choisi, sinon tous les sites.
    private var v3Source: RegSNMPCredentials? { scope == nil ? saved : siteSaved }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            snmpPanel
            RegRemoteCredentialsPanel()
        }
        .onAppear {
            load()
            tester.suggest(state)
        }
    }

    private var snmpPanel: some View {
        RegPanel(title: "Identifiants (SNMP)",
                 subtitle: "Utilisés partout où NetScope lit un agent SNMP\u{00A0}: switchs, Ressources, sondes, fiche matériel, découverte et Navigateur SNMP. SNMP v3 d’abord, la communauté en repli. Les secrets ne quittent jamais le Trousseau.",
                 accessory: {
                     HStack(spacing: 8) {
                         Button(action: testAll) { Label("Tout tester", systemImage: "play.fill") }
                             .buttonStyle(.secondary)
                             .regDisabled(tester.hostAddress == nil)
                             .help(tester.hostAddress == nil ? "Saisissez d’abord l’adresse à tester" : "Tester SNMP v2c, v3 et les identifiants SSH/WMI sur leur dernière adresse")
                     }
                 }, content: {
                     vaultBanner
                     testHostRow.padding(.top, 12)
                     // Côte à côte en grande fenêtre, l'un sous l'autre en petite.
                     RegColumns(minColumnWidth: 340) {
                         v2cBox
                         v3Box
                     }
                     .padding(.top, 14)
                     // L'état au-dessus, les boutons à gauche en dessous.
                     VStack(alignment: .leading, spacing: 8) {
                         status
                         ActionRow { actions }
                     }
                     .padding(.top, 14)
                 })
    }

    // MARK: Test SNMP

    private var testHostRow: some View {
        HStack(spacing: 10) {
            Text("Adresse à tester").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            RegTextField(placeholder: "ex. 10.182.122.2", text: $tester.host, mono: true,
                         invalid: !tester.host.isEmpty && tester.hostAddress == nil)
                .frame(width: 170)
            Text("Lecture de sysName, sysDescr et sysUpTime (UDP 161, délai 2\u{00A0}s, un renvoi).")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Communauté du test : celle saisie (pas encore enregistrée), sinon celle du Trousseau.
    private var testCommunity: String { draft.community.isEmpty ? (saved?.community ?? "") : draft.community }

    /// Identifiant v3 du test : champs saisis, secrets saisis ou enregistrés (du site choisi).
    private var testV3: SNMPv3Credentials {
        var merged = draft
        if merged.v3AuthPassword.isEmpty { merged.v3AuthPassword = v3Source?.v3AuthPassword ?? "" }
        if merged.v3PrivPassword.isEmpty { merged.v3PrivPassword = v3Source?.v3PrivPassword ?? "" }
        return merged.v3Credentials
    }

    private func testAll() {
        if !testCommunity.isEmpty { tester.testV2(community: testCommunity) }
        if !draft.v3User.isEmpty { tester.testV3(testV3) }
        for credential in remote.credentials where !credential.lastHost.isEmpty {
            remote.test(credential.id, host: credential.lastHost)
        }
    }

    private func testFooter(_ result: RegTestResult?, enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Theme.neutralSoft).frame(height: 1)
            Text(result?.text ?? "Pas encore testé dans cette session.")
                .font(.system(size: 12, weight: result == nil ? .regular : .semibold))
                .foregroundStyle(result.map { $0.tone.foreground } ?? Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ActionRow {
                Button(action: action) {
                    if result?.status == .running {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Test…") }
                    } else {
                        Label("Tester", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.secondary)
                .regDisabled(!enabled || result?.status == .running)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let message {
            Text(message.text).font(Theme.small).foregroundStyle(message.tone.foreground)
                .fixedSize(horizontal: false, vertical: true)
        } else if isDirty {
            Text("Modifications non enregistrées").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warning)
                .lineLimit(1)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(scope == nil ? "Effacer du Trousseau" : "Effacer l’utilisateur du site", role: .destructive, action: erase)
                .buttonStyle(.secondary)
                .regDisabled(scope == nil ? saved == nil : siteSaved == nil)
            Button("Annuler", action: { draft = mergedDraft(); message = nil })
                .buttonStyle(.secondary)
                .regDisabled(!isDirty)
            Button(action: save) { Label("Enregistrer dans le Trousseau", systemImage: "lock") }
                .buttonStyle(.primary)
                .regDisabled(!isDirty)
        }
        .fixedSize()
    }

    private var vaultBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trousseau macOS · service com.danymenard.netscope.snmp").font(Theme.bodySemibold)
                Text(vaultSummary).font(Theme.small)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(saved == nil && vault.perSite.isEmpty ? Theme.neutralText : Theme.success)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius)
            .fill(saved == nil && vault.perSite.isEmpty ? Theme.neutralSoft : Theme.successSoft))
    }

    private var vaultSummary: String {
        let common = saved?.configuredCount ?? 0
        let perSite = vault.perSite.count
        if common == 0 && perSite == 0 { return "Aucun identifiant enregistré." }
        var text = "\(common) identifiant(s) commun(s)"
        if perSite > 0 { text += " et \(perSite) utilisateur(s) v3 propre(s) à un site" }
        return text + ", chiffrés par macOS."
    }

    private func box<Content: View>(_ title: String, type: String, tone: Tone, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(Theme.bodySemibold)
                Chip(text: type, tone: tone)
                Spacer()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func secretPlaceholder(_ isSet: Bool) -> String {
        isSet ? "•••••••• (enregistré)" : "Non renseigné"
    }

    private var v2cBox: some View {
        box("Communauté en lecture", type: "SNMP v2c", tone: .warning) {
            RegField(label: "Communauté") {
                RegTextField(placeholder: secretPlaceholder(!(saved?.community.isEmpty ?? true)), text: $draft.community, mono: true, secure: true)
            }
            KeyValueRow(key: "Accès", value: "Lecture seule", keyWidth: 110)
            KeyValueRow(key: "Port", value: "UDP 161", mono: true, keyWidth: 110)
            Text("v2c transmet la communauté en clair sur le réseau : préférez SNMP v3 quand le switch le permet.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            testFooter(tester.v2, enabled: tester.hostAddress != nil && !testCommunity.isEmpty) {
                tester.testV2(community: testCommunity)
            }
        }
    }

    private var v3Box: some View {
        box("Utilisateur SNMP v3", type: "SNMP v3", tone: .success) {
            scopeRow
            // Grille : les libellés d'une même ligne sont alignés, menus et champs aussi.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                labelRow("Utilisateur", "Niveau de sécurité", first: true)
                GridRow {
                    RegTextField(placeholder: "ex. netscope-ro", text: $draft.v3User, mono: true)
                    Picker("", selection: $draft.v3Level) {
                        ForEach(RegSNMPCredentials.Level.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                if draft.v3Level != .noAuthNoPriv {
                    labelRow("Mot de passe auth.", "Authentification")
                    GridRow {
                        RegTextField(placeholder: secretPlaceholder(!(saved?.v3AuthPassword.isEmpty ?? true)), text: $draft.v3AuthPassword, mono: true, secure: true)
                        Picker("", selection: $draft.v3AuthProtocol) {
                            ForEach(RegSNMPCredentials.authProtocols, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                if draft.v3Level == .authPriv {
                    labelRow("Mot de passe priv.", "Confidentialité")
                    GridRow {
                        RegTextField(placeholder: secretPlaceholder(!(saved?.v3PrivPassword.isEmpty ?? true)), text: $draft.v3PrivPassword, mono: true, secure: true)
                        Picker("", selection: $draft.v3PrivProtocol) {
                            ForEach(RegSNMPCredentials.privProtocols, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                GridRow {
                    fieldLabel("Contexte (facultatif)").gridCellColumns(2).padding(.top, 6)
                }
                GridRow {
                    RegTextField(placeholder: "vide par défaut", text: $draft.v3Context, mono: true)
                        .gridCellColumns(2)
                }
            }
            sitesNote
            Spacer(minLength: 0)
            testFooter(tester.v3, enabled: tester.hostAddress != nil && !draft.v3User.isEmpty) {
                tester.testV3(testV3)
            }
        }
    }

    // MARK: Utilisateur v3 par site (note 59)

    /// « S'applique à » : tous les sites, ou un site qui a (ou aura) son propre utilisateur.
    private var scopeRow: some View {
        HStack(spacing: 10) {
            fieldLabel("S’applique à")
            Picker("", selection: $scope) {
                Text("Tous les sites (par défaut)").tag(UUID?.none)
                if !sites.sites.isEmpty { Divider() }
                ForEach(sites.sortedSites) { site in
                    Text(vault.perSite[site.id] == nil ? site.displayName : "\(site.displayName) · utilisateur propre")
                        .tag(UUID?.some(site.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .help("Un site peut avoir son propre utilisateur SNMP v3\u{00A0}; les autres utilisent celui de tous les sites.")
            Spacer(minLength: 0)
        }
        .onChange(of: scope) { _, _ in selectScope() }
    }

    /// Sites qui ont leur propre utilisateur v3.
    @ViewBuilder private var sitesNote: some View {
        let own = sites.sortedSites.compactMap { site in vault.perSite[site.id].map { (site, $0) } }
        if !own.isEmpty || scope != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let scope, let site = sites.site(scope) {
                    Text(siteSaved == nil
                         ? "«\u{00A0}\(site.displayName)\u{00A0}» n’a pas encore d’utilisateur propre\u{00A0}: celui de tous les sites sert pour ses switchs, ses plages et ses sondes."
                         : "Utilisé pour les switchs déclarés par «\u{00A0}\(site.displayName)\u{00A0}» et les adresses de ses plages.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !own.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Utilisateurs propres\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        ToolFlowLayout(spacing: 6) {
                            ForEach(own, id: \.0.id) { site, credentials in
                                Chip(text: "\(site.displayName) · \(credentials.user)", tone: site.id == scope ? .accent : .neutral)
                                    .help(credentials.summary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    /// Change de site : les champs v3 reprennent ceux de ce site (la communauté saisie reste).
    private func selectScope() {
        let community = draft.community
        if let scope {
            if RegEnvironment.isSandboxed {
                siteSaved = RegEnvironment.isDemo ? vault.perSite[scope].map { RegSNMPCredentials(v3: $0) } : nil
            } else {
                siteSaved = RegSNMPSiteVault.load(scope)
            }
        } else {
            siteSaved = nil
        }
        draft = mergedDraft()
        draft.community = community
        message = nil
    }

    /// Libellés d'une ligne de la grille v3 (même style que `RegField`).
    private func labelRow(_ left: String, _ right: String, first: Bool = false) -> some View {
        GridRow {
            fieldLabel(left)
            fieldLabel(right)
        }
        .padding(.top, first ? 0 : 6)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
    }

    // MARK: Trousseau

    private func load() {
        guard !loaded else { return }
        loaded = true
        if RegEnvironment.isSandboxed {
            // Démonstration : identifiants fictifs du croquis, rien n'est lu dans le Trousseau.
            if RegEnvironment.isDemo {
                var demo = RegSNMPCredentials()
                demo.community = "demo"
                demo.v3User = "ipscan-ro"
                demo.v3AuthPassword = "demo-auth"
                demo.v3PrivPassword = "demo-priv"
                saved = demo
                // Captures : NETSCOPE_V3_SITE=Siège ouvre l'utilisateur propre à ce site.
                if let name = ProcessInfo.processInfo.environment["NETSCOPE_V3_SITE"],
                   let site = sites.sites.first(where: { $0.displayName.localizedCaseInsensitiveContains(name) }) {
                    scope = site.id
                    siteSaved = vault.perSite[site.id].map { RegSNMPCredentials(v3: $0) }
                }
                draft = mergedDraft()
            }
            return
        }
        saved = RegSNMPCredentials.load()
        draft = mergedDraft()
    }

    /// Brouillon affiché : champs v3 du site choisi (ou de tous les sites), secrets laissés vides
    /// (ils restent au Trousseau).
    private func mergedDraft() -> RegSNMPCredentials {
        var copy = v3Source ?? RegSNMPCredentials()
        copy.community = ""
        copy.v3AuthPassword = ""
        copy.v3PrivPassword = ""
        return copy
    }

    private func save() {
        if !draft.v3AuthPassword.isEmpty, draft.v3AuthPassword.count < 8 {
            message = ("Mot de passe d’authentification trop court\u{00A0}: 8 caractères au moins (RFC 3414).", .critical)
            return
        }
        if !draft.v3PrivPassword.isEmpty, draft.v3PrivPassword.count < 8 {
            message = ("Mot de passe de confidentialité trop court\u{00A0}: 8 caractères au moins (RFC 3414).", .critical)
            return
        }
        /// Champs v3 du brouillon posés sur un identifiant enregistré (un secret vide garde l'ancien).
        func applyV3(to base: RegSNMPCredentials?) -> RegSNMPCredentials {
            var result = base ?? RegSNMPCredentials()
            result.v3User = draft.v3User.trimmingCharacters(in: .whitespaces)
            result.v3Level = draft.v3Level
            result.v3AuthProtocol = draft.v3AuthProtocol
            result.v3PrivProtocol = draft.v3PrivProtocol
            result.v3Context = draft.v3Context
            if !draft.v3AuthPassword.isEmpty { result.v3AuthPassword = draft.v3AuthPassword }
            if !draft.v3PrivPassword.isEmpty { result.v3PrivPassword = draft.v3PrivPassword }
            return result
        }
        do {
            // Communauté (commune à tous les sites) et utilisateur v3 de tous les sites : compte « identifiants ».
            var global = saved ?? RegSNMPCredentials()
            var globalChanged = false
            if !draft.community.isEmpty {
                global.community = draft.community
                globalChanged = true
            }
            if scope == nil {
                global = applyV3(to: global)
                globalChanged = true
            }
            // Utilisateur propre à un site : compte « v3-site-<UUID> ».
            if let scope {
                let site = applyV3(to: siteSaved)
                guard !site.v3User.isEmpty else {
                    message = ("Saisissez l’utilisateur SNMP v3 de ce site (ou choisissez «\u{00A0}Tous les sites\u{00A0}»).", .warning)
                    return
                }
                try RegSNMPSiteVault.save(site, for: scope)
                siteSaved = site
                vault.update(site: scope, credentials: site.v3Credentials)
            }
            if globalChanged {
                try global.save()
                SwitchStore.shared.credentialsSaved(community: global.community)
                saved = global
                if scope == nil { vault.update(global: global.v3User.isEmpty ? nil : global.v3Credentials) }
            }
            draft = mergedDraft()
            message = ("Enregistré dans le Trousseau.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }

    private func erase() {
        do {
            if let scope {
                try RegSNMPSiteVault.erase(scope)
                siteSaved = nil
                vault.update(site: scope, credentials: nil)
                draft = mergedDraft()
                message = ("Utilisateur SNMP v3 du site effacé du Trousseau\u{00A0}: celui de tous les sites sert désormais.", .success)
                return
            }
            try RegSNMPCredentials.erase()
            SwitchStore.shared.credentialsErased()
            vault.update(global: nil)
            saved = nil
            draft = RegSNMPCredentials()
            message = ("Identifiants effacés du Trousseau.", .success)
        } catch {
            message = (error.localizedDescription, .critical)
        }
    }
}
