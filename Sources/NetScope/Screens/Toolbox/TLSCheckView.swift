import AppKit
import NetScopeCore
import SwiftUI

/// Vérificateur de certificat TLS (note 70) : chaîne complète, SAN, validité, clé, signature,
/// empreintes, versions TLS acceptées et suite négociée, verdict de macOS ; puis, sur clic,
/// tous les HTTPS du dernier scan avec ceux qui sont expirés ou proches de l'expiration.
struct TLSCheckView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: TLSCheckModel
    @ObservedObject var store: ToolStore
    @StateObject private var chainTable = TLSChainTable.makeModel()
    @StateObject private var sweepTable = TLSSweepTable.makeModel()
    @State private var chainSelection: Int?
    @State private var sweepSelection = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            form
            if let error = model.error { ToolNotice(tone: .critical, message: error) }
            if model.isRunning {
                MailProgressLine(text: "Poignée TLS avec \(model.host):\(model.port), puis TLS\u{00A0}1.0 à 1.3 tentées une à une…")
            }
            if let inspection = model.inspection, !model.isRunning {
                result(inspection)
            } else if !model.isRunning, model.error == nil {
                Text("Lit le certificat présenté par un serveur (pare-feu, portail, imprimante, NAS, serveur de courriel)\u{00A0}: chaîne, noms couverts, dates, clé, signature et empreintes, versions TLS acceptées et verdict de confiance de macOS. Rien n’est envoyé au-delà de la poignée TLS.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.vertical, 4)
            sweepSection
        }
        .onAppear {
            if model.host.isEmpty, let gateway = state.activeInterface?.gateway?.description { model.host = gateway }
        }
    }

    // MARK: Formulaire

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Hôte (IP ou nom)") {
                    ToolTextField(placeholder: "fw.exemple.ca", text: $model.host) { start() }
                        .frame(minWidth: 200)
                }
                ToolLabeledField(label: "Port") {
                    HStack(spacing: 6) {
                        ToolTextField(placeholder: "443", text: $model.port, invalid: !model.port.isEmpty && model.portValue == nil) { start() }
                            .frame(width: 76)
                        portMenu
                    }
                }
                ToolLabeledField(label: "Nom SNI (facultatif)") {
                    ToolTextField(placeholder: "même que l’hôte", text: $model.serverName) { start() }
                        .frame(minWidth: 170)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    modePicker
                    thresholdPicker
                    Spacer(minLength: 8)
                    runButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        modePicker
                        thresholdPicker
                    }
                    runButton
                }
            }
        }
    }

    private var portMenu: some View {
        Menu {
            ForEach(TLSPortPreset.all) { preset in
                Button("\(preset.port) · \(preset.service)" + (preset.mode == .direct ? "" : " (\(preset.mode == .pop3 ? "STLS" : "STARTTLS"))")) {
                    model.choosePreset(preset)
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Ports TLS courants\u{00A0}: HTTPS, LDAPS, courriel (direct ou STARTTLS)")
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            Text("Chiffrement").font(Theme.small).foregroundStyle(Theme.textSecondary)
            Picker("Chiffrement", selection: Binding(get: { model.mode }, set: { model.chooseMode($0) })) {
                ForEach(TLSStartMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("STARTTLS\u{00A0}: partie en clair (EHLO, STARTTLS) puis TLS, comme le diagnostic SMTP. Choisi d’après le port.")
        }
    }

    private var thresholdPicker: some View {
        HStack(spacing: 6) {
            Text("Alerter").font(Theme.small).foregroundStyle(Theme.textSecondary)
            Picker("Alerter", selection: $model.warningDays) {
                ForEach(TLSCheckModel.thresholds, id: \.self) { days in Text("\(days)\u{00A0}jours avant").tag(days) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Un certificat qui expire dans moins de jours que ce seuil est signalé «\u{00A0}bientôt expiré\u{00A0}».")
        }
    }

    @ViewBuilder private var runButton: some View {
        if model.isRunning {
            Button { model.cancel() } label: { Label("Arrêter", systemImage: "stop.fill") }
                .buttonStyle(.secondary)
                .fixedSize()
        } else {
            Button { start() } label: { Label("Vérifier le certificat", systemImage: "lock.shield") }
                .buttonStyle(.primary)
                .fixedSize()
                .disabled(model.host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func start() {
        chainSelection = 0
        model.run(store: store)
    }

    // MARK: Résultat

    @ViewBuilder private func result(_ inspection: TLSInspection) -> some View {
        let verdict = TLSAnalysis.verdict(inspection, warningDays: model.warningDays)
        if let leaf = inspection.leaf {
            headline(inspection, leaf: leaf, verdict: verdict)
            ToolCellGrid(cells: cells(inspection, leaf: leaf), columns: 3, valueSize: 13, minCellWidth: 210, truncatesLongValues: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    findings(inspection).frame(minWidth: 380, maxWidth: .infinity)
                    versionsBox(inspection).frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 14) {
                    findings(inspection)
                    versionsBox(inspection)
                }
            }
            chainSection(inspection)
        } else {
            ToolNotice(tone: .critical, title: "Aucun certificat lu sur \(inspection.endpoint)",
                       message: (inspection.error ?? "La poignée TLS n’a pas abouti.")
                        + (inspection.mode == .direct && [25, 587, 143, 110].contains(inspection.port)
                           ? " Ce port s’ouvre d’habitude en clair\u{00A0}: choisir STARTTLS." : ""))
        }
    }

    private func headline(_ inspection: TLSInspection, leaf: X509Certificate, verdict: TLSVerdict) -> some View {
        let expiry = TLSExpiry.of(leaf, warningDays: model.warningDays)
        let title = leaf.subject.commonName ?? leaf.dnsNames.first ?? leaf.subject.text
        return VStack(alignment: .leading, spacing: 8) {
            ToolFieldLabel("Certificat de \(inspection.endpoint)" + (inspection.mode == .direct ? "" : " · \(inspection.mode.label)"))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(Theme.mono(22, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).textSelection(.enabled)
                    Chip(text: verdict.label, tone: verdict.level.tone)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(Theme.mono(18, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                    Chip(text: verdict.label, tone: verdict.level.tone)
                }
            }
            Text("Valide jusqu’au \(TLSFormat.date(leaf.notAfter)) (\(expiry.label)) · émis par \(leaf.isSelfIssued ? "lui-même (auto-signé)" : leaf.issuer.summary)")
                .font(Theme.small).foregroundStyle(expiry.level == .ok ? Theme.textSecondary : expiry.level.tone.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .contextMenu {
            Button("Copier le rapport") { ToolActions.copy(TLSAnalysis.report(inspection, warningDays: model.warningDays)) }
            Button("Copier le certificat (PEM)") { ToolActions.copy(leaf.pem) }.disabled(leaf.der.isEmpty)
        }
    }

    private func cells(_ inspection: TLSInspection, leaf: X509Certificate) -> [ToolCell] {
        let names = leaf.subjectAltNames.map(\.text)
        return [
            ToolCell(key: "Noms couverts (SAN)", value: names.first ?? "aucun SAN",
                     detail: names.count > 1 ? "+\(names.count - 1)\u{00A0}: " + names.dropFirst().joined(separator: ", ")
                        : names.isEmpty ? "CN\u{00A0}: \(leaf.subject.commonName ?? "—")" : "un seul nom"),
            ToolCell(key: "Émetteur", value: leaf.isSelfIssued ? "Auto-signé" : (leaf.issuer.commonName ?? leaf.issuer.summary),
                     detail: leaf.issuer.organization ?? leaf.issuer.text),
            ToolCell(key: "Validité", value: "\(TLSFormat.date(leaf.notBefore)) → \(TLSFormat.date(leaf.notAfter))",
                     detail: "\(TLSText.days(leaf.lifetimeDays)) au total"),
            ToolCell(key: "Clé publique", value: leaf.publicKey.label, detail: "Signature\u{00A0}: \(leaf.signatureAlgorithm)"),
            ToolCell(key: "Négocié", value: inspection.negotiatedVersion?.label ?? "—", detail: inspection.cipherSuite ?? "suite inconnue"),
            ToolCell(key: "Confiance macOS", value: inspection.trusted ? "Reconnu" : "Non reconnu",
                     detail: inspection.trusted ? "chaîne et nom vérifiés par SecTrust" : (inspection.trustReason ?? "chaîne non vérifiée")),
        ]
    }

    private func findings(_ inspection: TLSInspection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolFieldLabel("Constats")
            ToolFindingList(findings: TLSAnalysis.findings(inspection, warningDays: model.warningDays))
        }
    }

    private func versionsBox(_ inspection: TLSInspection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolFieldLabel("Versions TLS acceptées")
            VStack(spacing: 0) {
                let versions = inspection.versions.isEmpty
                    ? TLSVersion.allCases.reversed().map { TLSVersionSupport(version: $0, accepted: nil) } : inspection.versions
                ForEach(Array(versions.enumerated()), id: \.offset) { index, support in
                    HStack(spacing: 8) {
                        Text(support.version.label).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                            .frame(width: 62, alignment: .leading)
                        versionChip(support)
                        Spacer(minLength: 4)
                        if inspection.negotiatedVersion == support.version {
                            Text("négociée").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .help(support.detail ?? "")
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            if let ms = inspection.handshakeMs {
                Text("Poignée en \(PingFormat.decimal(ms))\u{00A0}ms" + (inspection.address.map { " · \($0)" } ?? ""))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func versionChip(_ support: TLSVersionSupport) -> Chip {
        switch support.accepted {
        case true?: return support.version.isObsolete ? Chip(text: "Acceptée (obsolète)", tone: .warning) : Chip(text: "Acceptée", tone: .success)
        case false?: return Chip(text: "Refusée", tone: .neutral)
        case nil: return Chip(text: "Non testée", tone: .neutral)
        }
    }

    // MARK: Chaîne

    private func chainSection(_ inspection: TLSInspection) -> some View {
        let rows = inspection.chain.enumerated().map { TLSChainRow(index: $0.offset, certificate: $0.element, count: inspection.chain.count) }
        let selected = min(max(chainSelection ?? model.selectedCertificate, 0), max(rows.count - 1, 0))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolFieldLabel("Chaîne envoyée par le serveur")
                Text("\(rows.count)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button { ToolActions.copy(inspection.chain.map(\.pem).joined()) } label: { Label("Copier en PEM", systemImage: "doc.on.doc") }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .disabled(inspection.chain.contains { $0.der.isEmpty })
                ToolColumnsMenu(model: chainTable)
            }
            TLSChainTable(rows: rows, table: chainTable, selection: Binding(get: { selected }, set: { chainSelection = $0 }),
                          warningDays: model.warningDays)
            if rows.indices.contains(selected) {
                certificateDetail(rows[selected])
            }
        }
    }

    private func certificateDetail(_ row: TLSChainRow) -> some View {
        let certificate = row.certificate
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolFieldLabel("Détail · \(row.role)")
                Spacer(minLength: 8)
                Button { ToolActions.copy(certificate.sha256Fingerprint) } label: { Label("Copier l’empreinte", systemImage: "number") }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
            }
            if !certificate.subjectAltNames.isEmpty {
                ToolFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(certificate.subjectAltNames.enumerated()), id: \.offset) { _, name in
                        Chip(text: "\(name.kind) \(name.text)", tone: .accent, mono: true)
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                detailRow("Sujet", certificate.subject.text)
                detailRow("Émetteur", certificate.issuer.text)
                detailRow("Validité", "du \(TLSFormat.date(certificate.notBefore)) au \(TLSFormat.date(certificate.notAfter)) · \(TLSExpiry.of(certificate, warningDays: model.warningDays).label)")
                detailRow("Clé · signature", "\(certificate.publicKey.label) · \(certificate.signatureAlgorithm)")
                detailRow("Numéro de série", certificate.serialNumber)
                detailRow("SHA-256", certificate.sha256Fingerprint)
                detailRow("Usage", usage(certificate))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(key).font(Theme.small).foregroundStyle(Theme.textSecondary).gridColumnAlignment(.leading)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func usage(_ certificate: X509Certificate) -> String {
        var parts: [String] = []
        if certificate.isCA == true { parts.append("autorité de certification") }
        if certificate.extendedKeyUsages.contains(X509OID.serverAuth) { parts.append("serveur TLS") }
        if certificate.extendedKeyUsages.contains(X509OID.clientAuth) { parts.append("client TLS") }
        if parts.isEmpty { parts.append(certificate.extendedKeyUsages.isEmpty ? "non précisé (tout usage)" : certificate.extendedKeyUsages.joined(separator: ", ")) }
        return parts.joined(separator: " · ") + " · X.509 v\(certificate.version)"
    }

    // MARK: Tous les HTTPS du site

    private var sweepSection: some View {
        let rows = sweepRows
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    sweepTitle
                    Spacer(minLength: 8)
                    sweepControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    sweepTitle
                    sweepControls
                }
            }
            if let notice = model.sweepNotice { ToolNotice(tone: .neutral, message: notice) }
            if model.sweepRunning {
                MailProgressLine(text: "\(model.sweepDone) sur \(model.sweepTotal) vérifiés, \(TLSSiteSweep.defaultConcurrency) à la fois…",
                                 fraction: model.sweepTotal > 0 ? Double(model.sweepDone) / Double(model.sweepTotal) : nil)
            }
            if !model.sweepResults.isEmpty {
                sweepSummary
                TLSSweepTable(rows: rows, table: sweepTable, selection: $sweepSelection,
                              emptyText: "Aucun certificat expiré ni proche de l’expiration (seuil\u{00A0}: \(model.warningDays)\u{00A0}jours).",
                              show: { model.show($0) }, device: device(for:))
            }
        }
    }

    private var sweepTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            ToolFieldLabel("Tous les HTTPS du site")
            Text("Appareils du dernier scan avec 443 ou 8443 ouvert, \(TLSSiteSweep.defaultConcurrency) à la fois, seulement sur clic.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sweepControls: some View {
        HStack(spacing: 10) {
            ToolCheckbox(label: "Expirés ou bientôt seulement", isOn: $model.sweepOnlyProblems)
            if model.sweepRunning {
                Button { model.cancelSweep() } label: { Label("Arrêter", systemImage: "stop.fill") }
                    .buttonStyle(.secondary)
                    .fixedSize()
            } else {
                Button { model.sweep(devices: state.devices) } label: { Label("Vérifier tous les HTTPS du site", systemImage: "checkmark.shield") }
                    .buttonStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private var sweepRows: [TLSSweepRow] {
        let all = model.sweepResults.map { TLSSweepRow(inspection: $0, warningDays: model.warningDays) }
        return model.sweepOnlyProblems ? all.filter { $0.verdict.isExpiryProblem } : all
    }

    private var sweepSummary: some View {
        let verdicts = model.sweepResults.map { TLSAnalysis.verdict($0, warningDays: model.warningDays) }
        let expired = verdicts.filter { if case .expired = $0 { return true } else { return $0 == .notYetValid } }.count
        let soon = verdicts.filter { if case .soon = $0 { return true } else { return false } }.count
        let selfSigned = verdicts.filter { $0 == .selfSigned }.count
        let failed = verdicts.filter { $0 == .failed }.count
        return ToolFlowLayout(spacing: 6, lineSpacing: 6) {
            Chip(text: "\(expired) expiré\(expired > 1 ? "s" : "")", tone: expired > 0 ? .critical : .neutral)
            Chip(text: "\(soon) bientôt", tone: soon > 0 ? .warning : .neutral)
            Chip(text: "\(selfSigned) auto-signé\(selfSigned > 1 ? "s" : "")", tone: .neutral)
            if failed > 0 { Chip(text: "\(failed) sans réponse TLS", tone: .neutral) }
            Text("\(model.sweepResults.count) vérifiés" + (model.sweepDate.map { " · \(ToolText.relative($0))" } ?? ""))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .padding(.leading, 4)
        }
    }

    private func device(for host: String) -> NavObject? {
        state.devices.first { $0.ip.description == host }.map { .device(NavDeviceRef($0)) }
    }
}

// MARK: - Tableau de la chaîne

struct TLSChainRow: Identifiable {
    let index: Int
    let certificate: X509Certificate
    let count: Int

    var id: Int { index }
    var role: String {
        if index == 0 { return "Serveur" }
        return certificate.isSelfIssued ? "Racine" : "Intermédiaire"
    }
    var subjectText: String { certificate.subject.summary }
    var issuerText: String { certificate.isSelfIssued ? "lui-même" : certificate.issuer.summary }
    var notAfter: Date { certificate.notAfter }
    var keyText: String { certificate.publicKey.label }
    var signatureText: String { certificate.signatureAlgorithm }
}

/// Chaîne envoyée par le serveur (tableau standard « outils.tls.chaine »).
struct TLSChainTable: View {
    let rows: [TLSChainRow]
    @ObservedObject var table: StandardTableModel<TLSChainRow>
    @Binding var selection: Int
    let warningDays: Int

    static let columns: [StandardColumn] = [
        StandardColumn(id: "role", title: "Rôle", isRequired: true),
        StandardColumn(id: "sujet", title: "Sujet"),
        StandardColumn(id: "emetteur", title: "Émetteur"),
        StandardColumn(id: "fin", title: "Expire le"),
        StandardColumn(id: "restant", title: "Restant"),
        StandardColumn(id: "cle", title: "Clé"),
        StandardColumn(id: "signature", title: "Signature", isDefaultVisible: false),
        StandardColumn(id: "empreinte", title: "SHA-256", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<TLSChainRow>] = [
        "role": KeyPathComparator(\TLSChainRow.index),
        "sujet": KeyPathComparator(\TLSChainRow.subjectText),
        "emetteur": KeyPathComparator(\TLSChainRow.issuerText),
        "fin": KeyPathComparator(\TLSChainRow.notAfter),
        "restant": KeyPathComparator(\TLSChainRow.notAfter),
        "cle": KeyPathComparator(\TLSChainRow.keyText),
        "signature": KeyPathComparator(\TLSChainRow.signatureText),
        "empreinte": KeyPathComparator(\TLSChainRow.certificate.sha256Fingerprint),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<TLSChainRow> {
        StandardTableModel(id: "outils.tls.chaine", columns: columns, sortKeys: sortKeys, defaultSort: "role")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 6) {
            Table(sorted, selection: Binding(get: { Optional(selection) }, set: { if let value = $0 { selection = value } }),
                  sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("RÔLE", sortUsing: table.sort("role")) { row in
                    ToolTableText(row.role, mono: false, weight: .semibold)
                }
                .width(min: 76, ideal: 88, max: 120)
                .customizationID("role")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("SUJET", sortUsing: table.sort("sujet")) { row in
                    ToolTableText(row.subjectText).help(row.certificate.subject.text)
                }
                .width(min: 110, ideal: 140)
                .customizationID("sujet")

                TableColumn("ÉMETTEUR", sortUsing: table.sort("emetteur")) { row in
                    ToolTableText(row.issuerText, color: Theme.textSecondary).help(row.certificate.issuer.text)
                }
                .width(min: 110, ideal: 140)
                .customizationID("emetteur")

                TableColumn("EXPIRE LE", sortUsing: table.sort("fin")) { row in
                    ToolTableText(TLSFormat.date(row.notAfter))
                }
                .width(min: 80, ideal: 88)
                .customizationID("fin")

                TableColumn("RESTANT", sortUsing: table.sort("restant")) { row in
                    let expiry = TLSExpiry.of(row.certificate, warningDays: warningDays)
                    ToolTableText(expiry.label, mono: false, weight: expiry.level == .ok ? .regular : .semibold,
                                  color: expiry.level == .ok ? Theme.textSecondary : expiry.level.tone.foreground)
                }
                .width(min: 100, ideal: 120)
                .customizationID("restant")

                TableColumn("CLÉ", sortUsing: table.sort("cle")) { row in
                    ToolTableText(row.keyText, color: row.certificate.publicKey.isWeak ? Theme.warning : Theme.text)
                }
                .width(min: 80, ideal: 104)
                .customizationID("cle")

                TableColumn("SIGNATURE", sortUsing: table.sort("signature")) { row in
                    ToolTableText(row.signatureText, mono: false, color: row.certificate.hasWeakSignature ? Theme.warning : Theme.textSecondary)
                }
                .width(min: 100, ideal: 130)
                .customizationID("signature")
                .defaultVisibility(.hidden)

                TableColumn("SHA-256", sortUsing: table.sort("empreinte")) { row in
                    ToolTableText(TLSFormat.shortFingerprint(row.certificate.sha256Fingerprint), color: Theme.textSecondary)
                        .help(row.certificate.sha256Fingerprint)
                }
                .width(min: 120, ideal: 170)
                .customizationID("empreinte")
                .defaultVisibility(.hidden)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Copier l’empreinte SHA-256") {
                    ToolActions.copy(rows.filter { ids.contains($0.index) }.map(\.certificate.sha256Fingerprint).joined(separator: "\n"))
                }
                Button("Copier en PEM") {
                    ToolActions.copy(rows.filter { ids.contains($0.index) }.map(\.certificate.pem).joined())
                }
                .disabled(rows.contains { ids.contains($0.index) && $0.certificate.der.isEmpty })
            }
        }
    }
}

// MARK: - Tableau du site

extension TLSVerdict {
    /// Libellé court pour une colonne étroite (« Bientôt » au lieu de « Expire dans 12 jours »).
    var shortLabel: String {
        switch self {
        case .soon: return "Bientôt"
        default: return label
        }
    }
}

struct TLSSweepRow: Identifiable {
    let inspection: TLSInspection
    let verdict: TLSVerdict
    let expiry: TLSExpiry?

    init(inspection: TLSInspection, warningDays: Int) {
        self.inspection = inspection
        verdict = TLSAnalysis.verdict(inspection, warningDays: warningDays)
        expiry = TLSAnalysis.expiry(inspection, warningDays: warningDays)
    }

    var id: UUID { inspection.id }
    var name: String { inspection.label ?? inspection.host }
    var endpoint: String { inspection.endpoint }
    var sortAddress: UInt32 { IPv4Address(inspection.host)?.value ?? .max }
    var verdictRank: Int { verdict.rank }
    var daysLeft: Int { expiry?.daysRemaining ?? .max }
    var issuerText: String {
        guard let leaf = inspection.leaf else { return inspection.error ?? "—" }
        return leaf.isSelfIssued ? "Auto-signé" : leaf.issuer.summary
    }
    var subjectText: String { inspection.leaf?.subject.summary ?? "—" }
    /// « dans 12 jours », « il y a 1 405 jours » (le verdict dit déjà « Expiré » ou « Expire dans »).
    var remainingText: String {
        switch expiry {
        case let .valid(days)?, let .soon(days)?: return "dans \(TLSText.days(days))"
        case let .expired(daysAgo)?: return "il y a \(TLSText.days(daysAgo))"
        case .notYetValid?: return "pas encore valide"
        case nil: return "—"
        }
    }
}

/// Certificats des HTTPS du site (tableau standard « outils.tls.site »).
struct TLSSweepTable: View {
    let rows: [TLSSweepRow]
    @ObservedObject var table: StandardTableModel<TLSSweepRow>
    @Binding var selection: Set<UUID>
    let emptyText: String
    let show: (TLSInspection) -> Void
    let device: (String) -> NavObject?

    static let columns: [StandardColumn] = [
        StandardColumn(id: "appareil", title: "Appareil", isRequired: true),
        StandardColumn(id: "adresse", title: "Adresse"),
        StandardColumn(id: "verdict", title: "Verdict"),
        StandardColumn(id: "restant", title: "Restant"),
        StandardColumn(id: "emetteur", title: "Émetteur"),
        StandardColumn(id: "sujet", title: "Sujet", isDefaultVisible: false),
    ]

    static let sortKeys: [String: KeyPathComparator<TLSSweepRow>] = [
        "appareil": KeyPathComparator(\TLSSweepRow.name),
        "adresse": KeyPathComparator(\TLSSweepRow.sortAddress),
        "verdict": KeyPathComparator(\TLSSweepRow.verdictRank),
        "restant": KeyPathComparator(\TLSSweepRow.daysLeft),
        "emetteur": KeyPathComparator(\TLSSweepRow.issuerText),
        "sujet": KeyPathComparator(\TLSSweepRow.subjectText),
    ]

    @MainActor
    static func makeModel() -> StandardTableModel<TLSSweepRow> {
        StandardTableModel(id: "outils.tls.site", columns: columns, sortKeys: sortKeys, defaultSort: "restant")
    }

    var body: some View {
        let sorted = rows.sorted(using: table.sortOrder)
        ToolStandardTableFrame(rowCount: sorted.count, maxRows: 10, emptyText: emptyText) {
            Table(sorted, selection: $selection, sortOrder: $table.sortOrder, columnCustomization: $table.customization) {
                TableColumn("APPAREIL", sortUsing: table.sort("appareil")) { row in
                    ToolTableText(row.name, mono: false, weight: .medium)
                }
                .width(min: 100, ideal: 130)
                .customizationID("appareil")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("ADRESSE", sortUsing: table.sort("adresse")) { row in
                    ToolTableText(row.endpoint, color: Theme.textSecondary)
                }
                .width(min: 100, ideal: 135)
                .customizationID("adresse")

                TableColumn("VERDICT", sortUsing: table.sort("verdict")) { row in
                    ToolTableText(row.verdict.shortLabel, mono: false, weight: .semibold,
                                  color: row.verdict.level == .ok ? Theme.success : row.verdict.level.tone.foreground)
                        .help(row.inspection.trustReason ?? row.inspection.error ?? "")
                }
                .width(min: 80, ideal: 96)
                .customizationID("verdict")

                TableColumn("RESTANT", sortUsing: table.sort("restant")) { row in
                    if let expiry = row.expiry, let leaf = row.inspection.leaf {
                        ToolTableText(row.remainingText, mono: false,
                                      color: expiry.level == .ok ? Theme.textSecondary : expiry.level.tone.foreground)
                            .help("Fin de validité\u{00A0}: \(TLSFormat.date(leaf.notAfter))")
                    } else {
                        ToolTableText("—", color: Theme.textSecondary)
                    }
                }
                .width(min: 110, ideal: 140)
                .customizationID("restant")

                TableColumn("ÉMETTEUR", sortUsing: table.sort("emetteur")) { row in
                    ToolTableText(row.issuerText, mono: false, color: Theme.textSecondary)
                }
                .width(min: 80, ideal: 120)
                .customizationID("emetteur")

                TableColumn("SUJET", sortUsing: table.sort("sujet")) { row in
                    ToolTableText(row.subjectText, color: Theme.textSecondary)
                }
                .width(min: 100, ideal: 180)
                .customizationID("sujet")
                .defaultVisibility(.hidden)
            }
            .standardRowActions(selection: Array(selection), object: { id in
                rows.first { $0.id == id }.flatMap { device($0.inspection.host) }
            }, primary: { ids in
                guard let row = rows.first(where: { ids.contains($0.id) }) else { return false }
                show(row.inspection)
                return true
            }) { ids in
                Button("Afficher le détail") {
                    if let row = rows.first(where: { ids.contains($0.id) }) { show(row.inspection) }
                }
                .disabled(ids.isEmpty)
                Button("Copier") {
                    ToolActions.copy(rows.filter { ids.contains($0.id) }
                        .map { "\($0.name)\t\($0.endpoint)\t\($0.verdict.label)\t\($0.expiry?.label ?? "—")\t\($0.issuerText)" }
                        .joined(separator: "\n"))
                }
                .disabled(ids.isEmpty)
            }
        }
    }
}
