import AppKit
import NetScopeCore
import SwiftUI

/// FortiGate à ajouter ou à modifier (feuille d'édition).
struct RegFortiControllerDraft: Identifiable {
    var controller: FortiGateController
    var isNew: Bool
    /// Résultat d'essai préparé (captures seulement).
    var outcome: FortiGateStore.TestOutcome?

    var id: UUID { controller.id }

    /// Captures : NETSCOPE_FORTIGATE_FEUILLE=siege (ou laval, quebec, drummondville, nouveau)
    /// dessine la feuille dans la page, avec le résultat d'un « Tester » de démonstration.
    @MainActor
    static var snapshotDraft: RegFortiControllerDraft? {
        guard RegEnvironment.isSnapshot, let raw = ProcessInfo.processInfo.environment["NETSCOPE_FORTIGATE_FEUILLE"] else { return nil }
        let store = FortiGateStore.shared
        let ids = ["siege": FortiGateSitesDemo.siegeID, "laval": FortiGateSitesDemo.lavalID,
                   "quebec": FortiGateSitesDemo.quebecID, "drummondville": FortiGateSitesDemo.drummondID]
        if let id = ids[raw], let c = store.controller(id) {
            var draft = RegFortiControllerDraft(controller: c, isNew: false)
            if id == FortiGateSitesDemo.siegeID {
                // Plages à compléter : le « Tester » propose les sous-réseaux des interfaces.
                draft.controller.ranges = ["10.182.122.0/24"]
            }
            draft.outcome = FortiGateSitesDemo.testOutcome(for: c)
            return draft
        }
        return RegFortiControllerDraft(controller: FortiGateController(site: "Bureau Sherbrooke", host: "10.50.0.1"), isNew: true)
    }
}

/// Feuille d'ajout ou de modification d'une FortiGate : site, adresse, port, VDOM, plages couvertes,
/// jeton (Trousseau), empreinte du certificat à accepter et « Tester », qui propose les
/// sous-réseaux des interfaces à cocher. Rien n'est enregistré avant « Enregistrer ».
struct RegFortiControllerEditor: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fortigate = FortiGateStore.shared
    let dismiss: () -> Void
    /// Dessinée dans la page (captures) plutôt que dans une feuille : sans défilement propre.
    var inline = false
    private let isNew: Bool
    private let original: FortiGateController

    @State private var site: String
    @State private var host: String
    @State private var port: String
    @State private var vdom: String
    @State private var rangesText: String
    @State private var isEnabled: Bool
    @State private var pinned: String?
    @State private var token = ""
    @State private var outcome: FortiGateStore.TestOutcome?
    @State private var testing = false
    @State private var error: String?
    @State private var copied = false
    /// Empreinte acceptée depuis le dernier essai : invite neutre à tester de nouveau.
    @State private var acceptedNotice = false

    init(draft: RegFortiControllerDraft, inline: Bool = false, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        self.inline = inline
        isNew = draft.isNew
        original = draft.controller
        _site = State(initialValue: draft.controller.site)
        _host = State(initialValue: draft.controller.host)
        _port = State(initialValue: String(draft.controller.port))
        _vdom = State(initialValue: draft.controller.vdom)
        _rangesText = State(initialValue: draft.controller.ranges.joined(separator: ", "))
        _isEnabled = State(initialValue: draft.controller.isEnabled)
        _pinned = State(initialValue: draft.controller.pinnedFingerprint)
        _outcome = State(initialValue: draft.outcome)
    }

    // MARK: Brouillon

    private var portValue: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65_535).contains($0) ? $0 : nil } }
    private var hostInvalid: Bool { !host.isEmpty && !FortiGateConfig(host: host).isValid }
    private var parsedRanges: (ranges: [FortiCoveredRange], invalid: [String]) {
        // Blocs séparés par des virgules, points-virgules ou lignes ; dans un bloc, parseList lit les
        // espaces et garde « 10.0.0.0 255.255.255.0 » (adresse puis masque) en une seule plage.
        FortiCoveredRange.parseLenient(FortiCoveredRange.splitBlocks(rangesText))
    }

    private var draft: FortiGateController {
        var c = original
        c.site = site
        c.host = host
        c.port = portValue ?? 443
        c.vdom = vdom
        c.ranges = parsedRanges.ranges.map(\.text)
        c.isEnabled = isEnabled
        c.pinnedFingerprint = pinned
        return c
    }

    private var target: (String, Int) { (draft.config.cleanHost.lowercased(), draft.config.effectivePort) }
    private var hasStoredToken: Bool { fortigate.hasToken(original.id) }
    private var canSave: Bool {
        !site.trimmingCharacters(in: .whitespaces).isEmpty && !host.isEmpty && !hostInvalid && portValue != nil && parsedRanges.invalid.isEmpty
    }

    /// Plages couvertes par d'autres FortiGate qui chevauchent celles-ci, calculées dans l'ordre réel
    /// de la liste (le brouillon à la place de l'original, ou à la fin s'il est nouveau) : « première
    /// de la liste » désigne bien celle que le choix retiendra.
    private var overlaps: [FortiRangeConflict] {
        var list = fortigate.controllers
        if let index = list.firstIndex(where: { $0.id == original.id }) {
            list[index] = draft
        } else {
            list.append(draft)
        }
        let active = list.filter { $0.isEnabled || $0.id == original.id }
        return FortiControllerSelector.conflicts(active).filter { $0.first == original.id || $0.second == original.id }
    }

    // MARK: Vue

    var body: some View {
        if inline {
            VStack(alignment: .leading, spacing: 0) {
                form
                Divider()
                footer
            }
            .background(Theme.panel)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView { form }
                Divider()
                footer
            }
            .frame(minWidth: 560, idealWidth: 640, maxWidth: 720, minHeight: 420, idealHeight: 640)
            .background(Theme.panel)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(SwitchSource.fortigate.colors.foreground)
                Text(isNew ? "Nouvelle FortiGate" : "Modifier «\u{00A0}\(original.displayName)\u{00A0}»").font(Theme.panelTitle)
                Spacer()
                Toggle("Activée", isOn: $isEnabled).toggleStyle(.switch).controlSize(.small)
            }
            fields
            rangesBox
            tokenBox
            certificateBox
            testBox
            if let error {
                RegNotice(error, tone: .critical)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !isNew {
                Text("Compte du Trousseau\u{00A0}: \(original.keychainAccount.prefix(8))…").font(Theme.small).foregroundStyle(Theme.textTertiary)
                    .help("Service com.danymenard.netscope.fortigate, compte \(original.keychainAccount)")
            }
            Spacer()
            Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
            Button(isNew ? "Ajouter" : "Enregistrer", action: save)
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .regDisabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            RegField(label: "Site") {
                RegTextField(placeholder: "ex. Entrepôt Laval", text: $site)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 10) {
                    hostField.frame(minWidth: 200)
                    portField.frame(width: 100)
                    vdomField.frame(width: 140)
                }
                VStack(alignment: .leading, spacing: 8) {
                    hostField
                    HStack(alignment: .bottom, spacing: 10) {
                        portField.frame(width: 100)
                        vdomField.frame(width: 140)
                    }
                }
            }
            if hostInvalid {
                Text("Adresse invalide\u{00A0}: saisissez l’adresse IP ou le nom de la FortiGate (ex. 10.20.0.1), sans «\u{00A0}https://\u{00A0}».")
                    .font(Theme.small).foregroundStyle(Theme.critical)
            } else if portValue == nil {
                Text("Port invalide\u{00A0}: un nombre de 1 à 65\u{202F}535 (443 par défaut).").font(Theme.small).foregroundStyle(Theme.critical)
            }
        }
    }

    private var hostField: some View {
        RegField(label: "Adresse de la FortiGate") {
            RegTextField(placeholder: "ex. 10.20.0.1", text: $host, mono: true, invalid: hostInvalid)
        }
    }

    private var portField: some View {
        RegField(label: "Port HTTPS") {
            RegTextField(placeholder: "443", text: $port, mono: true, invalid: portValue == nil)
        }
    }

    private var vdomField: some View {
        RegField(label: "VDOM (facultatif)") {
            RegTextField(placeholder: "root", text: $vdom, mono: true)
        }
    }

    // MARK: Plages couvertes

    private var rangesBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            RegField(label: "Plages couvertes") {
                RegTextField(placeholder: "ex. 10.20.0.0/16, 10.21.0.0/24", text: $rangesText, mono: true, invalid: !parsedRanges.invalid.isEmpty)
            }
            if !parsedRanges.invalid.isEmpty {
                Text("Plage illisible\u{00A0}: " + parsedRanges.invalid.joined(separator: ", ") + " (ex. 10.20.0.0/16, 10.20.0.1-10.20.0.50).")
                    .font(Theme.small).foregroundStyle(Theme.critical)
            } else {
                Text("Cette FortiGate est lue quand une plage scannée y entre ou la chevauche, ou, à défaut, quand l’adresse de ce Mac y est. Séparez les plages par des virgules ou des espaces. «\u{00A0}Tester\u{00A0}» propose les sous-réseaux de ses interfaces.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(overlaps) { conflict in
                RegNotice(conflict.message, tone: conflict.isAmbiguous ? .warning : .neutral)
            }
        }
    }

    // MARK: Jeton

    private var tokenBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Jeton de l’administrateur API REST").font(Theme.bodySemibold)
                if !token.isEmpty {
                    Chip(text: "À enregistrer", tone: .accent)
                } else if hasStoredToken {
                    Chip(text: "Enregistré", tone: .success, systemImage: "lock.fill")
                } else {
                    Chip(text: "Manquant", tone: .warning, systemImage: "lock.open")
                }
                Spacer()
            }
            RegTextField(placeholder: hasStoredToken ? "Enregistré au Trousseau (laisser vide pour le garder)" : "coller le jeton affiché par la FortiGate",
                         text: $token, mono: true, secure: true, invalid: !token.isEmpty && FortiGateStore.tokenProblem(token) != nil)
            if !token.isEmpty, let problem = FortiGateStore.tokenProblem(token) {
                Text(problem).font(Theme.small).foregroundStyle(Theme.critical)
            }
            Text("Gardé au Trousseau macOS, un compte par FortiGate (service com.danymenard.netscope.fortigate). Il part seulement dans l’en-tête «\u{00A0}Authorization\u{00A0}» des requêtes HTTPS vers cette FortiGate, jamais dans une adresse, un journal, le CSV, une sauvegarde ou les réponses copiées.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Certificat

    private var pending: FortiGateStore.PendingCertificate? { outcome?.pending }

    private var certificateBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Certificat HTTPS").font(Theme.bodySemibold)
                if pending?.changed == true {
                    Chip(text: "Empreinte changée", tone: .critical)
                } else if pending != nil {
                    Chip(text: "À accepter", tone: .warning)
                } else if pinned != nil {
                    Chip(text: "Empreinte acceptée", tone: .success)
                } else {
                    Chip(text: "Inconnu", tone: .neutral)
                }
                Spacer()
            }
            if let pending {
                Text(pending.changed
                     ? "Le certificat présenté ne correspond plus à l’empreinte acceptée\u{00A0}: la connexion a été refusée. N’acceptez la nouvelle empreinte qu’après l’avoir vérifiée sur la FortiGate (certificat renouvelé)."
                     : "Premier contact\u{00A0}: comparez cette empreinte SHA-256 avec celle du certificat de la FortiGate (System › Certificates, ou le cadenas du navigateur sur https://\(draft.config.cleanHost)) avant de l’accepter.")
                    .font(Theme.small).foregroundStyle(pending.changed ? Theme.critical : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !pending.subject.isEmpty {
                    Text("Sujet\u{00A0}: \(pending.subject)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                RegFingerprintText(fingerprint: pending.fingerprint)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Refuser") {
                        outcome?.pending = nil
                        // L'invite « Premier contact » de l'essai ne vaut plus : seul le refus s'affiche.
                        outcome?.error = nil
                        error = "Certificat refusé\u{00A0}: aucune connexion à cette FortiGate."
                    }
                    .buttonStyle(.secondary)
                    Button("Accepter cette empreinte") { acceptPending() }.buttonStyle(.primary)
                }
            } else if let pinned {
                RegFingerprintText(fingerprint: pinned)
                HStack {
                    Text(draft.sameTarget(as: original) || original.pinnedFingerprint != pinned
                         ? "Toute connexion dont le certificat a une autre empreinte est refusée."
                         : "Adresse changée\u{00A0}: cette empreinte sera oubliée à l’enregistrement.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Oublier l’empreinte") { self.pinned = nil }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
            } else {
                Text("La FortiGate utilise en général un certificat autosigné. Au premier «\u{00A0}Tester\u{00A0}», son empreinte SHA-256 s’affiche ici\u{00A0}: vous l’acceptez une fois, puis toute autre empreinte est refusée.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func acceptPending() {
        guard let pending else { return }
        outcome?.pending = nil
        outcome?.error = nil
        guard pending.host == target.0, pending.port == target.1 else {
            error = "L’adresse a changé depuis l’essai\u{00A0}: testez de nouveau pour vérifier le certificat."
            return
        }
        pinned = pending.fingerprint
        error = nil
        acceptedNotice = true
    }

    // MARK: Tester

    private var testBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    testTitle
                    Spacer(minLength: 8)
                    testButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    testTitle
                    testButtons
                }
            }
            if acceptedNotice, pinned != nil {
                RegNotice("Empreinte acceptée\u{00A0}: cliquez sur «\u{00A0}Tester\u{00A0}» pour lire la FortiGate.", tone: .neutral)
            }
            if let outcome {
                if let message = outcome.error, outcome.pending == nil || outcome.pending?.changed == true {
                    RegNotice(message, tone: .critical)
                }
                if let report = outcome.report {
                    RegTileRow {
                        RegTile("Modèle", report.system.model.isEmpty ? "—" : report.system.model)
                        RegTile("Version de FortiOS", report.system.versionLabel, mono: true)
                        RegTile("Nom d’hôte", report.controllerName, mono: true)
                        RegTile("FortiSwitch gérés", "\(report.switches.count)")
                        RegTile("Appareils détectés", "\(report.locatedDevices.count)")
                    }
                    interfacesBox(outcome.interfaces)
                }
                RegFortiCallsSummary(calls: outcome.calls)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var testTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tester la connexion").font(Theme.bodySemibold)
            Text(outcome.map { "Dernier essai\u{00A0}: \(SwitchText.dateTime($0.date))" } ?? "Lit le modèle, la version de FortiOS, les FortiSwitch et les sous-réseaux des interfaces.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var testButtons: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copié" : "Copier les réponses brutes (diagnostic)") {
                if fortigate.controller(original.id) != nil {
                    fortigate.copyDiagnostic(original.id, calls: outcome?.calls)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(FortiDiagnostic.text(calls: outcome?.calls ?? [], config: draft.config, system: outcome?.report?.system,
                                                                        token: token, date: outcome?.date ?? Date()), forType: .string)
                }
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
            .buttonStyle(.secondary)
            .regDisabled((outcome?.calls ?? []).isEmpty)
            .help("Copie les réponses JSON de chaque appel du dernier essai, sans le jeton, pour ajuster la lecture à votre version de FortiOS.")
            Button(action: test) {
                HStack(spacing: 6) {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "Test…" : "Tester")
                }
            }
            .buttonStyle(.primary)
            .regDisabled(testing || host.isEmpty || hostInvalid || portValue == nil || (token.isEmpty && !hasStoredToken))
        }
        .fixedSize()
    }

    /// Sous-réseaux des interfaces : une case par sous-réseau, cochée s'il est dans les plages.
    @ViewBuilder private func interfacesBox(_ interfaces: [FortiInterfaceSubnet]) -> some View {
        let lan = interfaces.filter { !$0.isFortiLink }
        let fortilink = interfaces.filter(\.isFortiLink)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RegLabel("Sous-réseaux des interfaces de la FortiGate")
                Spacer(minLength: 8)
                if lan.contains(where: { $0.isSuggested && !isChecked($0) }) {
                    Button("Cocher les réseaux locaux") {
                        for item in lan where item.isSuggested { setChecked(item, true) }
                    }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                }
            }
            if interfaces.isEmpty {
                Text("Aucun sous-réseau lu (droit «\u{00A0}Network\u{00A0}» en lecture absent du profil\u{00A0}?). Saisissez les plages à la main.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(lan) { item in interfaceRow(item) }
            if !fortilink.isEmpty {
                Text("Réseau FortiLink (non coché\u{00A0}: les FortiSwitch y sont lus par la FortiGate, jamais scannés)")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
                ForEach(fortilink) { item in interfaceRow(item) }
            }
        }
        .padding(.top, 4)
    }

    private func interfaceRow(_ item: FortiInterfaceSubnet) -> some View {
        Toggle(isOn: Binding(get: { isChecked(item) }, set: { setChecked(item, $0) })) {
            HStack(spacing: 8) {
                Text(item.subnet.description).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(item.label).font(Theme.small).foregroundStyle(Theme.textSecondary)
                if item.role?.lowercased() == "wan" { Chip(text: "WAN", tone: .neutral) }
                if !item.subnet.isPrivate { Chip(text: "adresse publique", tone: .warning) }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func isChecked(_ item: FortiInterfaceSubnet) -> Bool {
        let range = FortiCoveredRange(subnet: item.subnet)
        return parsedRanges.ranges.contains { $0 == range }
    }

    private func setChecked(_ item: FortiInterfaceSubnet, _ on: Bool) {
        var list = parsedRanges.ranges.map(\.text)
        let text = item.subnet.description
        if on {
            if !list.contains(text) { list.append(text) }
        } else {
            list.removeAll { $0 == text }
        }
        rangesText = list.joined(separator: ", ")
    }

    // MARK: Actions

    private func test() {
        testing = true
        error = nil
        acceptedNotice = false
        let candidate = draft
        let typed = token
        Task { @MainActor in
            let result = await fortigate.test(candidate, typedToken: typed)
            testing = false
            outcome = result
            // Première lecture : les réseaux locaux sont proposés cochés si aucune plage n'est saisie.
            if result.ok, parsedRanges.ranges.isEmpty {
                for item in result.interfaces where item.isSuggested { setChecked(item, true) }
            }
            // Seulement si l'essai visait la FortiGate enregistrée (même adresse et port) : un essai
            // sur une autre adresse, puis « Annuler », ne doit rien écrire sur celle-ci.
            if !isNew { fortigate.recordTest(result, for: original.id, target: candidate) }
        }
    }

    private func save() {
        if let problem = fortigate.save(draft, token: token, state: state) {
            error = problem
            return
        }
        dismiss()
    }
}
