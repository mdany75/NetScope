import AppKit
import NetScopeCore
import SwiftUI

/// Réglages › Switchs › Contrôleur FortiGate (note 24) : adresse, port HTTPS, VDOM, jeton de
/// l'administrateur API REST au Trousseau, empreinte du certificat acceptée, bouton Tester et aide
/// pas à pas. NetScope ne lit que la FortiGate, jamais les FortiSwitch.
struct RegFortiGatePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fortigate = FortiGateStore.shared
    @State private var host = ""
    @State private var port = "443"
    @State private var vdom = ""
    @State private var tokenText = ""
    @State private var tokenMessage: (text: String, tone: Tone)?
    @State private var loaded = false
    @State private var showHelp = false
    @State private var copied = false
    @StateObject private var switchTable = RegFortiSwitchTable.makeModel()

    var body: some View {
        RegPanel(title: "Contrôleur FortiGate",
                 subtitle: "FortiSwitch gérés par FortiLink\u{00A0}: NetScope lit la FortiGate par son API REST (HTTPS, lecture seule) et n’interroge jamais les switchs, dont les adresses FortiLink (10.255.1.0/24 par défaut) ne sont pas joignables depuis ce Mac. La FortiGate passe avant SNMP pour le switch, le port et le VLAN de chaque appareil.") {
            statusChip
        } content: {
            RegToggleRow(title: "Lire la FortiGate à chaque scan",
                         detail: "À la fin de chaque scan et avec «\u{00A0}Interroger les switchs\u{00A0}», NetScope relit les FortiSwitch gérés, leurs ports, le PoE, les appareils détectés, la table ARP et les baux DHCP de la FortiGate (requêtes GET seulement\u{00A0}: rien n’est jamais modifié).",
                         isOn: $fortigate.isEnabled)
            connectionFields
                .padding(.top, 10)
            tokenBox
                .padding(.top, 14)
            certificateBox
                .padding(.top, 14)
            testBox
                .padding(.top, 14)
            helpBox
                .padding(.top, 14)
        }
        .onAppear(perform: load)
        .task { await fortigate.loadToken() }
    }

    @ViewBuilder private var statusChip: some View {
        if fortigate.isBusy {
            Chip(text: "Lecture…", tone: .accent)
        } else if fortigate.testOK == true {
            Chip(text: "Connectée", tone: .success)
        } else if fortigate.testOK == false {
            Chip(text: "Erreur", tone: .critical)
        } else if fortigate.isConfigured {
            Chip(text: "À tester", tone: .neutral)
        } else {
            Chip(text: "Non configurée", tone: .neutral)
        }
    }

    // MARK: Adresse

    private var hostInvalid: Bool { !host.isEmpty && !FortiGateConfig(host: host).isValid }
    private var portValue: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65_535).contains($0) ? $0 : nil } }
    private var fieldsChanged: Bool {
        host.trimmingCharacters(in: .whitespaces) != fortigate.config.host || portValue != fortigate.config.port
            || vdom.trimmingCharacters(in: .whitespaces) != fortigate.config.vdom
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 10) {
                    hostField.frame(minWidth: 220)
                    portField.frame(width: 110)
                    vdomField.frame(width: 150)
                    saveAddressButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    hostField
                    HStack(alignment: .bottom, spacing: 10) {
                        portField.frame(width: 110)
                        vdomField.frame(width: 150)
                        Spacer(minLength: 8)
                        saveAddressButton
                    }
                }
            }
            if hostInvalid {
                Text("Adresse invalide\u{00A0}: saisissez l’adresse IP ou le nom de la FortiGate (ex. 10.182.122.1), sans «\u{00A0}https://\u{00A0}».")
                    .font(Theme.small).foregroundStyle(Theme.critical)
            } else if portValue == nil {
                Text("Port invalide\u{00A0}: un nombre de 1 à 65\u{202F}535 (443 par défaut).").font(Theme.small).foregroundStyle(Theme.critical)
            }
        }
    }

    private var hostField: some View {
        RegField(label: "Adresse de la FortiGate") {
            RegTextField(placeholder: "ex. 10.182.122.1", text: $host, mono: true, invalid: hostInvalid)
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

    private var saveAddressButton: some View {
        Button("Enregistrer") {
            fortigate.update(host: host, port: portValue ?? 443, vdom: vdom)
            host = fortigate.config.host
        }
        .buttonStyle(.primary)
        .regDisabled(!fieldsChanged || hostInvalid || portValue == nil)
        .fixedSize()
    }

    // MARK: Jeton

    private var tokenBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Jeton de l’administrateur API REST").font(Theme.bodySemibold)
                if fortigate.hasToken {
                    Chip(text: "Enregistré au Trousseau", tone: .success)
                } else {
                    Chip(text: "Absent", tone: .warning)
                }
                Spacer()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    tokenField
                    tokenButtons
                }
                VStack(alignment: .trailing, spacing: 8) {
                    tokenField
                    tokenButtons
                }
            }
            if let tokenMessage {
                Text(tokenMessage.text).font(Theme.small).foregroundStyle(tokenMessage.tone.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Trousseau macOS · service com.danymenard.netscope.fortigate, compte «\u{00A0}jeton\u{00A0}». Le jeton part seulement dans l’en-tête «\u{00A0}Authorization\u{00A0}» des requêtes HTTPS vers cette FortiGate, jamais dans une adresse, un journal ou les réponses copiées.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var tokenField: some View {
        RegTextField(placeholder: fortigate.hasToken ? "••••••••••••••••••••••••••••••" : "coller le jeton affiché par la FortiGate",
                     text: $tokenText, mono: true, secure: true)
    }

    private var tokenButtons: some View {
        HStack(spacing: 8) {
            Button("Effacer") {
                fortigate.eraseToken()
                tokenMessage = ("Jeton effacé du Trousseau.", .neutral)
            }
            .buttonStyle(.secondary)
            .regDisabled(!fortigate.hasToken || fortigate.isDemo)
            Button {
                if let error = fortigate.saveToken(tokenText) {
                    tokenMessage = (error, .critical)
                } else {
                    tokenText = ""
                    tokenMessage = ("Jeton enregistré au Trousseau.", .success)
                }
            } label: { Label("Enregistrer au Trousseau", systemImage: "lock") }
                .buttonStyle(.primary)
                .regDisabled(tokenText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .fixedSize()
    }

    // MARK: Certificat

    private var certificateBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Certificat HTTPS de la FortiGate").font(Theme.bodySemibold)
                if fortigate.pendingCertificate?.changed == true {
                    Chip(text: "Empreinte changée", tone: .critical)
                } else if fortigate.pendingCertificate != nil {
                    Chip(text: "À accepter", tone: .warning)
                } else if fortigate.config.pinnedFingerprint != nil {
                    Chip(text: "Empreinte acceptée", tone: .success)
                } else {
                    Chip(text: "Inconnu", tone: .neutral)
                }
                Spacer()
            }
            if let pending = fortigate.pendingCertificate {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pending.changed
                         ? "Le certificat présenté ne correspond plus à l’empreinte acceptée\u{00A0}: la connexion a été refusée. N’acceptez la nouvelle empreinte qu’après l’avoir vérifiée sur la FortiGate (certificat renouvelé)."
                         : "Premier contact\u{00A0}: comparez cette empreinte SHA-256 avec celle du certificat de la FortiGate (System › Certificates, ou le cadenas du navigateur sur https://\(fortigate.config.cleanHost)) avant de l’accepter.")
                        .font(Theme.small).foregroundStyle(pending.changed ? Theme.critical : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !pending.subject.isEmpty {
                        Text("Sujet\u{00A0}: \(pending.subject)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    fingerprintText(pending.fingerprint)
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Refuser") { fortigate.rejectPendingCertificate() }.buttonStyle(.secondary)
                        Button("Accepter cette empreinte") { fortigate.acceptPendingCertificate() }.buttonStyle(.primary)
                    }
                }
            } else if let pinned = fortigate.config.pinnedFingerprint {
                fingerprintText(pinned)
                HStack {
                    Text("Toute connexion dont le certificat a une autre empreinte est refusée.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Oublier l’empreinte") { fortigate.forgetCertificate() }
                        .buttonStyle(.secondary)
                        .regDisabled(fortigate.isDemo)
                        .fixedSize()
                }
            } else {
                Text("La FortiGate utilise en général un certificat autosigné. Au premier «\u{00A0}Tester\u{00A0}», son empreinte SHA-256 s’affiche ici\u{00A0}: vous l’acceptez une fois, puis toute autre empreinte est refusée. Aucun certificat n’est jamais accepté sans votre accord.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func fingerprintText(_ fingerprint: String) -> some View {
        Text(FortiCertificatePin.display(fingerprint))
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
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
            if let error = fortigate.lastError {
                RegNotice(error, tone: fortigate.pendingCertificate != nil && fortigate.pendingCertificate?.changed == false ? .warning : .critical)
            }
            if let report = fortigate.report {
                RegTileRow {
                    RegTile("Modèle", report.system.model.isEmpty ? "—" : report.system.model)
                    RegTile("Version de FortiOS", report.system.versionLabel, mono: true)
                    RegTile("Nom d’hôte", report.controllerName, mono: true)
                    RegTile("FortiSwitch gérés", "\(report.switches.count)")
                    RegTile("Appareils détectés", "\(report.locatedDevices.count)")
                    RegTile("Table ARP · baux DHCP", "\(report.arp.count) · \(report.dhcp.count)")
                }
                if !report.switches.isEmpty {
                    HStack {
                        RegLabel("FortiSwitch lus par la FortiGate")
                        Spacer(minLength: 8)
                        Text("Lu \(SwitchText.ago(report.readAt))").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        StandardColumnsMenu(model: switchTable)
                    }
                    .padding(.top, 4)
                    RegFortiSwitchTable(table: switchTable, report: report)
                        .regTableFrame()
                }
                callsSummary
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var testTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tester la connexion").font(Theme.bodySemibold)
            Text(fortigate.lastAttempt.map { "Dernier essai\u{00A0}: \(SwitchText.dateTime($0))" } ?? "Lit le modèle, la version de FortiOS, les FortiSwitch et les appareils détectés.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
    }

    private var testButtons: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copié" : "Copier les réponses brutes (diagnostic)") {
                fortigate.copyDiagnostic()
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
            .buttonStyle(.secondary)
            .regDisabled(fortigate.lastCalls.isEmpty)
            .help("Copie les réponses JSON de chaque appel de la dernière lecture, sans le jeton, pour ajuster la lecture à votre version de FortiOS.")
            Button {
                fortigate.test()
            } label: {
                HStack(spacing: 6) {
                    if fortigate.isBusy { ProgressView().controlSize(.small) }
                    Text(fortigate.isBusy ? "Test…" : "Tester")
                }
            }
            .buttonStyle(.primary)
            .regDisabled(fortigate.isBusy || !fortigate.config.isValid || !fortigate.hasToken)
        }
        .fixedSize()
    }

    /// Bilan des appels de la dernière lecture : adresses absentes de cette version ou refusées.
    @ViewBuilder private var callsSummary: some View {
        let missing = fortigate.lastCalls.filter { $0.outcome == .absent }
        let refused = fortigate.lastCalls.filter { $0.outcome == .refused || $0.outcome == .failed }
        if !missing.isEmpty || !refused.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(refused, id: \.path) { call in
                    Text("Refusé\u{00A0}: \(call.path)" + (call.status.map { " (HTTP \($0))" } ?? "") + (call.message.isEmpty ? "" : " — \(call.message)"))
                        .font(Theme.small).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !missing.isEmpty {
                    Text("Absent de cette version de FortiOS (ignoré)\u{00A0}: " + missing.map(\.path).joined(separator: ", "))
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Aide

    private var helpBox: some View {
        DisclosureGroup(isExpanded: $showHelp) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(helpSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 18, alignment: .trailing)
                        Text(step).font(Theme.small).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Créer l’administrateur API REST en lecture seule (pas à pas)").font(Theme.bodySemibold)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var helpSteps: [String] {
        let mac = state.activeInterface?.address.description ?? "l’adresse IP de ce Mac"
        return [
            "Sur la FortiGate (ou dans FortiManager, si elle y est gérée), ouvrez System › Admin Profiles › Create New. Nom\u{00A0}: «\u{00A0}netscope-lecture\u{00A0}». Mettez tout à «\u{00A0}None\u{00A0}», sauf «\u{00A0}WiFi & Switch Controller\u{00A0}» en «\u{00A0}Read\u{00A0}» (indispensable). Pour la table ARP, les baux DHCP et les noms d’appareils, ajoutez «\u{00A0}Network\u{00A0}», «\u{00A0}System\u{00A0}» et «\u{00A0}User & Device\u{00A0}» en «\u{00A0}Read\u{00A0}». Aucun droit en écriture.",
            "System › Administrators › Create New › REST API Admin. Nom\u{00A0}: «\u{00A0}netscope\u{00A0}», profil\u{00A0}: «\u{00A0}netscope-lecture\u{00A0}». Laissez «\u{00A0}PKI Group\u{00A0}» et «\u{00A0}CORS\u{00A0}» décochés.",
            "Cochez «\u{00A0}Trusted Hosts\u{00A0}» et saisissez \(mac)/32\u{00A0}: le jeton ne sera accepté que depuis ce Mac. Une autre adresse donnera «\u{00A0}Accès refusé (HTTP 403)\u{00A0}».",
            "Cliquez OK\u{00A0}: la FortiGate affiche le jeton une seule fois. Copiez-le, collez-le ci-dessus et cliquez «\u{00A0}Enregistrer au Trousseau\u{00A0}».",
            "Vérifiez que l’accès HTTPS d’administration est permis sur l’interface que joint ce Mac (Network › Interfaces › Administrative Access › HTTPS) et le port HTTPS (System › Settings, 443 par défaut, souvent 8443 ou 10443).",
            "Saisissez l’adresse de la FortiGate, le port et, seulement en mode multi-VDOM, le VDOM des FortiSwitch. Cliquez «\u{00A0}Tester\u{00A0}»\u{00A0}: au premier contact, comparez l’empreinte du certificat avec celle de la FortiGate puis acceptez-la, et cliquez de nouveau «\u{00A0}Tester\u{00A0}».",
            "Si une donnée manque (version de FortiOS différente), cliquez «\u{00A0}Copier les réponses brutes (diagnostic)\u{00A0}»\u{00A0}: le jeton en est retiré, le texte peut être transmis pour ajuster la lecture.",
        ]
    }

    // MARK: Chargement

    private func load() {
        guard !loaded else { return }
        loaded = true
        host = fortigate.config.host
        port = String(fortigate.config.port)
        vdom = fortigate.config.vdom
        // Captures : l'aide pas à pas est dépliée.
        if RegEnvironment.isSnapshot { showHelp = ProcessInfo.processInfo.environment["NETSCOPE_FORTIGATE_AIDE"] == "1" }
    }
}

/// Ligne du tableau des FortiSwitch lus par la FortiGate.
struct RegFortiSwitchRow: Identifiable {
    let id: String
    let name: String
    let model: String
    let serial: String
    let firmware: String
    let address: String
    let addressSort: UInt32
    let status: String
    let connected: Bool
    let ports: String
    let devices: Int
}

/// FortiSwitch lus par la FortiGate (tableau standard « reglages.fortiswitch »).
struct RegFortiSwitchTable: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var table: StandardTableModel<RegFortiSwitchRow>
    let report: FortiGateReport

    static let columns: [StandardColumn] = [
        StandardColumn(id: "nom", title: "Nom", isRequired: true),
        StandardColumn(id: "modele", title: "Modèle"),
        StandardColumn(id: "logiciel", title: "Logiciel"),
        StandardColumn(id: "adresse", title: "Adresse FortiLink"),
        StandardColumn(id: "etat", title: "État"),
        StandardColumn(id: "appareils", title: "Appareils détectés"),
        StandardColumn(id: "serie", title: "Numéro de série", isDefaultVisible: false),
        StandardColumn(id: "ports", title: "Ports actifs", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<RegFortiSwitchRow>] = [
        "nom": KeyPathComparator(\RegFortiSwitchRow.name),
        "modele": KeyPathComparator(\RegFortiSwitchRow.model),
        "logiciel": KeyPathComparator(\RegFortiSwitchRow.firmware),
        "adresse": KeyPathComparator(\RegFortiSwitchRow.addressSort),
        "etat": KeyPathComparator(\RegFortiSwitchRow.status),
        "appareils": KeyPathComparator(\RegFortiSwitchRow.devices),
        "serie": KeyPathComparator(\RegFortiSwitchRow.serial),
        "ports": KeyPathComparator(\RegFortiSwitchRow.ports),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<RegFortiSwitchRow> {
        StandardTableModel(id: "reglages.fortiswitch", columns: columns, sortKeys: sortKeys, defaultSort: "nom")
    }

    var body: some View {
        let located = report.locatedDevices
        let rows = report.switches.map { sw -> RegFortiSwitchRow in
            let up = sw.ports.filter { $0.linkUp == true }.count
            let status: String
            switch (sw.connected, sw.state?.lowercased()) {
            case (false?, _): status = "Déconnecté"
            case (_, "authorized"?): status = "Connecté · autorisé"
            case (_, "discovered"?): status = "Découvert · à autoriser"
            case (_, "unauthorized"?), (_, "deauthorized"?): status = "Non autorisé"
            default: status = "Connecté"
            }
            return RegFortiSwitchRow(id: sw.switchID, name: sw.name, model: sw.model.isEmpty ? "FortiSwitch" : sw.model, serial: sw.serial,
                                     firmware: sw.firmware, address: sw.fortilinkIP?.description ?? "—",
                                     addressSort: sw.fortilinkIP?.value ?? .max, status: status, connected: sw.connected != false,
                                     ports: "\(up) / \(sw.ports.count)",
                                     devices: located.filter { sw.keys.contains($0.switchID.lowercased()) }.count)
        }
        .sorted(using: table.sortOrder)
        Table(rows, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
            TableColumn("NOM", sortUsing: table.sort("nom")) { row in
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Text(row.name).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .frame(height: RegSwitchTableMetrics.rowHeight - 8)
            }
            .width(min: 110, ideal: 140)
            .customizationID("nom")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("MODÈLE", sortUsing: table.sort("modele")) { row in
                RegSwitchCell(row.model, secondary: true)
            }
            .width(min: 90, ideal: 110)
            .customizationID("modele")

            TableColumn("LOGICIEL", sortUsing: table.sort("logiciel")) { row in
                RegSwitchCell(row.firmware, mono: true)
            }
            .width(min: 60, ideal: 80)
            .customizationID("logiciel")

            TableColumn("ADRESSE FORTILINK", sortUsing: table.sort("adresse")) { row in
                RegSwitchCell(row.address, mono: true)
                    .help("Adresse sur le réseau FortiLink, non joignable depuis ce Mac\u{00A0}: le switch est lu par la FortiGate.")
            }
            .width(min: 90, ideal: 120)
            .customizationID("adresse")

            TableColumn("ÉTAT", sortUsing: table.sort("etat")) { row in
                Chip(text: row.status, tone: row.connected ? .success : .critical)
            }
            .width(min: 80, ideal: 100)
            .customizationID("etat")

            TableColumn("APPAREILS DÉTECTÉS", sortUsing: table.sort("appareils")) { row in
                RegSwitchCell("\(row.devices)", mono: true)
            }
            .width(min: 70, ideal: 110)
            .customizationID("appareils")

            TableColumn("NUMÉRO DE SÉRIE", sortUsing: table.sort("serie")) { row in
                RegSwitchCell(row.serial, mono: true)
            }
            .width(min: 100, ideal: 140)
            .customizationID("serie")
            .defaultVisibility(.hidden)

            TableColumn("PORTS ACTIFS", sortUsing: table.sort("ports")) { row in
                RegSwitchCell(row.ports, mono: true)
            }
            .width(min: 60, ideal: 90)
            .customizationID("ports")
            .defaultVisibility(.hidden)
        }
        .standardTableStyle()
        .contextMenu(forSelectionType: RegFortiSwitchRow.ID.self) { ids in
            if let id = ids.first, let host = host(of: id) {
                Button("Ouvrir dans « Switchs et ports »") {
                    SwitchStore.shared.select(host: host)
                    state.open(.switchs)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let host = host(of: id) {
                SwitchStore.shared.select(host: host)
                state.open(.switchs)
            }
        }
        .frame(height: RegSwitchTableMetrics.height(rows: rows.count))
    }

    /// Adresse du relevé affiché pour ce FortiSwitch dans « Switchs et ports ».
    @MainActor
    private func host(of id: String) -> String? {
        guard let sw = report.switches.first(where: { $0.switchID == id }) else { return nil }
        return SwitchStore.shared.controllerSnapshots.first { $0.system.name == sw.name }?.host.description
    }
}
