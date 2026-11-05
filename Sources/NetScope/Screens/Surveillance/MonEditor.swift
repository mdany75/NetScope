import NetScopeCore
import SwiftUI

/// Panneau « Éditeur de sonde » : les changements restent dans un brouillon jusqu'à « Enregistrer ».
struct MonEditor: View {
    @ObservedObject private var store = MonStore.shared
    @State private var draft: MonProbe?
    /// Emplacement de la sonde enregistrée quand le brouillon a été ouvert : tant que le brouillon
    /// le garde tel quel, c'est l'emplacement appris depuis par le moteur qui compte.
    @State private var originLocation: String?
    @State private var confirmDelete = false
    /// Case « Courriel, webhook » du brouillon (nil : inchangée) : appliquée à « Enregistrer ».
    @State private var alertsExcluded: Bool?
    @ObservedObject private var alerts = AlertDispatcher.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let saved = store.selectedProbe, let draft, draft.id == saved.id {
                form(saved: saved, draft: draftBinding(draft))
            } else {
                MonHeading("Éditeur de sonde")
                Text("Aucune sonde. «\u{00A0}Nouvelle sonde\u{00A0}» en crée une, préremplie avec la passerelle.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let toast = store.toast { RegNotice(toast, tone: .success) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .monPanel()
        .onAppear(perform: reload)
        .onChange(of: store.selectedProbe?.id) { _, _ in reload() }
        .onChange(of: store.probes) { _, _ in
            // Changement venu d'ailleurs (interrupteur, apprentissage, enregistrement) : repris si rien n'est en cours.
            guard let saved = store.selectedProbe else { draft = nil; return }
            if var current = draft, current.id == saved.id, isDirty(saved: saved, draft: current) {
                // Brouillon en cours : seul l'emplacement appris est repris, s'il n'a pas été touché.
                if current.expectedLocation == originLocation, current.expectedLocation != saved.expectedLocation {
                    current.expectedLocation = saved.expectedLocation
                    draft = current
                }
                originLocation = saved.expectedLocation
                return
            }
            draft = saved
            originLocation = saved.expectedLocation
        }
        .confirmationDialog("Supprimer la sonde «\u{00A0}\(draft?.name ?? "")\u{00A0}»\u{00A0}?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { if let id = draft?.id { store.delete(id) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Son historique de 24\u{00A0}h est effacé\u{00A0}; ses entrées restent au journal des alertes.")
        }
    }

    private func reload() {
        alertsExcluded = nil
        draft = store.selectedProbe
        originLocation = draft?.expectedLocation
    }

    private func draftBinding(_ value: MonProbe) -> Binding<MonProbe> {
        Binding(get: { draft ?? value }, set: { draft = $0 })
    }

    /// Brouillon prêt à enregistrer : l'interrupteur et les MAC apprises restent ceux de la sonde.
    private func normalized(_ draft: MonProbe, saved: MonProbe) -> MonProbe {
        var probe = draft
        probe.isEnabled = saved.isEnabled
        probe.knownMACs = saved.knownMACs
        if probe.expectedLocation == originLocation { probe.expectedLocation = saved.expectedLocation }
        return probe
    }

    private func isDirty(saved: MonProbe, draft: MonProbe) -> Bool {
        normalized(draft, saved: saved) != saved || exclusionChanged(saved.id)
    }

    private func isExcluded(_ id: UUID) -> Bool { alerts.settings.rules.excludedProbes.contains(id) }

    private func exclusionChanged(_ id: UUID) -> Bool {
        alertsExcluded.map { $0 != isExcluded(id) } ?? false
    }

    /// Case « Courriel, webhook » : cochée quand la sonde n'est pas exclue (valeur du brouillon).
    private func alertsBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !(alertsExcluded ?? isExcluded(id)) }, set: { alertsExcluded = !$0 })
    }

    // MARK: Formulaire

    @ViewBuilder private func form(saved: MonProbe, draft: Binding<MonProbe>) -> some View {
        let state = store.state(of: saved)
        HStack(spacing: 8) {
            MonHeading("Éditeur de sonde")
            RegPill(text: MonText.label(state), tone: MonText.tone(state))
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(nextLabel(saved, at: store.demoNow ?? context.date))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }

        field("Nom") {
            MonInput(placeholder: "Nom de la sonde", text: draft.name, font: .system(size: 13, weight: .semibold), height: 32)
        }
        HStack(alignment: .top, spacing: 8) {
            field("Type") {
                MonMenuField(title: draft.wrappedValue.kind.label) {
                    ForEach(MonProbeKind.allCases) { kind in
                        Button(kind.label) {
                            // La limite n'a pas la même unité d'un type à l'autre (%, Mb/s) :
                            // le nouveau type part de sa valeur par défaut.
                            if draft.wrappedValue.kind != kind { draft.wrappedValue.resourceLimit = nil }
                            draft.wrappedValue.kind = kind
                            MonResourceConditionFields.prepare(&draft.wrappedValue)
                            MonServiceConditionFields.prepare(&draft.wrappedValue)
                            MonDHCPScopeConditionFields.prepare(&draft.wrappedValue)
                            MonWANConditionFields.prepare(&draft.wrappedValue)
                            MonFirmwareConditionFields.prepare(&draft.wrappedValue)
                        }
                    }
                }
            }
            field("Intervalle") {
                MonMenuField(title: MonProbe.intervalMenuLabel(draft.wrappedValue.interval)) {
                    ForEach(MonProbe.intervals, id: \.self) { seconds in
                        Button(MonProbe.intervalMenuLabel(seconds)) { draft.wrappedValue.interval = seconds }
                    }
                }
            }
        }
        field("Cible") {
            MonInput(placeholder: draft.wrappedValue.kind.targetPlaceholder, text: draft.target, mono: true)
        }
        field("Condition d’alerte propre au type") {
            MonConditionFields(probe: draft)
        }
        MonFieldset("Seuils") {
            HStack(alignment: .top, spacing: 8) {
                // Processeur, mémoire, port saturé : ni latence ni perte mesurées, seuils sans objet.
                if ![MonProbeKind.cpu, .memory, .portLoad].contains(draft.wrappedValue.kind) {
                    small("Latence > (ms)") {
                        MonInput(placeholder: "—", text: optionalNumber(draft.thresholds.latencyMs), mono: true, height: 28)
                    }
                    small("Perte > (%)") {
                        MonInput(placeholder: "—", text: optionalNumber(draft.thresholds.lossPercent), mono: true, height: 28)
                    }
                }
                small("Échecs consécutifs") {
                    MonInput(placeholder: "3", text: failuresText(draft), mono: true, height: 28)
                }
            }
        }
        field("Plage horaire des alertes") {
            MonMenuField(title: draft.wrappedValue.schedule.label) {
                ForEach(MonSchedule.allCases) { schedule in
                    Button(schedule.label) { draft.wrappedValue.schedule = schedule }
                }
            }
        }
        dependencyRow(draft)
        MonFieldset("Actions d’alerte") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 14) {
                    ToolCheckbox(label: "Notification macOS", isOn: draft.notify)
                    ToolCheckbox(label: "Son", isOn: draft.sound)
                }
                MonAlertChannelsRow(probeID: saved.id, isOn: alertsBinding(saved.id))
                soonRow("Exécuter un script", placeholder: "~/Scripts/…")
            }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                testButton(saved: saved, draft: draft)
                saveButton(saved: saved, draft: draft)
                Spacer(minLength: 0)
                deleteButton
            }
            HStack(spacing: 6) {
                testButton(saved: saved, draft: draft)
                saveButton(saved: saved, draft: draft)
                Spacer(minLength: 0)
                deleteButton.labelStyle(.iconOnly).help("Supprimer la sonde")
            }
        }
        if let test = store.manualTests[saved.id] {
            RegNotice(MonJournal.clock(test.date) + " · " + test.text, tone: test.tone)
        }
        if let toast = store.toast {
            RegNotice(toast, tone: .success)
        }
    }

    private func testButton(saved: MonProbe, draft: Binding<MonProbe>) -> some View {
        Button { store.testNow(saved.id) } label: {
            Label(store.running.contains(saved.id) ? "Test en cours…" : "Tester maintenant", systemImage: "play.fill")
        }
        .buttonStyle(.primary)
        .fixedSize()
        .disabled(store.running.contains(saved.id) || saved.target.trimmingCharacters(in: .whitespaces).isEmpty)
        .help(isDirty(saved: saved, draft: draft.wrappedValue) ? "Teste la sonde enregistrée (enregistrez d’abord vos changements)" : "Vérifier la sonde tout de suite")
    }

    private func saveButton(saved: MonProbe, draft: Binding<MonProbe>) -> some View {
        Button {
            store.save(normalized(draft.wrappedValue, saved: saved))
            if let excluded = alertsExcluded, excluded != isExcluded(saved.id) { alerts.setExcluded(excluded, probe: saved.id) }
            alertsExcluded = nil
        } label: {
            Label("Enregistrer", systemImage: "checkmark")
        }
        .buttonStyle(.secondary)
        .fixedSize()
        .disabled(!isDirty(saved: saved, draft: draft.wrappedValue))
    }

    private var deleteButton: some View {
        Button { confirmDelete = true } label: {
            Label("Supprimer", systemImage: "trash")
                .foregroundStyle(Theme.critical)
        }
        .buttonStyle(MonDangerButtonStyle())
        .fixedSize()
    }

    private func nextLabel(_ probe: MonProbe, at date: Date) -> String {
        guard let left = store.nextCheck(of: probe, at: date) else { return "Sonde inactive" }
        if store.running.contains(probe.id) { return "Vérification…" }
        let seconds = Int(left.rounded(.up))
        return "Prochaine vérif. " + (seconds <= 90 ? "\(seconds)\u{00A0}s" : "\(Int((Double(seconds) / 60).rounded(.up)))\u{00A0}min")
    }

    @ViewBuilder private func dependencyRow(_ draft: Binding<MonProbe>) -> some View {
        let others = store.probes.filter { $0.id != draft.wrappedValue.id }
        let current = others.first { $0.id == draft.wrappedValue.dependsOn }
        let defaultParent = others.first { $0.kind == .ping && $0.target == store.gatewayAddress } ?? others.first
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding(get: { draft.wrappedValue.dependsOn != nil && current != nil },
                                 set: { draft.wrappedValue.dependsOn = $0 ? defaultParent?.id : nil })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(others.isEmpty)
            VStack(alignment: .leading, spacing: 5) {
                (Text("Dépendance\u{00A0}:").fontWeight(.semibold)
                 + Text(" ignorer si \(dependencyName(current ?? defaultParent)) est hors ligne"))
                    .font(Theme.small)
                    .foregroundStyle(others.isEmpty ? Theme.textTertiary : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if current != nil, others.count > 1 {
                    Menu {
                        ForEach(others) { probe in
                            Button(probe.name) { draft.wrappedValue.dependsOn = probe.id }
                        }
                    } label: {
                        Text("Changer de sonde parente").font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                    .tint(Theme.accentStrong)
                }
            }
        }
    }

    private func dependencyName(_ probe: MonProbe?) -> String {
        guard let probe else { return "une autre sonde" }
        if probe.kind == .ping, probe.target == store.gatewayAddress { return "la passerelle \(probe.target)" }
        return "«\u{00A0}\(probe.name)\u{00A0}»"
    }

    private func soonRow(_ title: String, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: .constant(false)) { Text(title).font(Theme.small) }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(true)
                .frame(width: 132, alignment: .leading)
            Text(placeholder)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        }
        .help("Bientôt\u{00A0}: le script d’alerte n’est pas encore offert.")
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func small<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.9)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Adaptateurs de saisie

    private func optionalNumber(_ value: Binding<Double?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(MonFormat.number) ?? "" },
                set: { text in
                    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                    value.wrappedValue = cleaned.isEmpty ? nil : Double(cleaned).map { max(0, $0) } ?? value.wrappedValue
                })
    }

    private func failuresText(_ draft: Binding<MonProbe>) -> Binding<String> {
        Binding(get: { String(draft.wrappedValue.thresholds.failures) },
                set: { text in
                    if let value = Int(text.trimmingCharacters(in: .whitespaces)) {
                        draft.wrappedValue.thresholds.failures = min(20, max(1, value))
                    }
                })
    }
}

/// Champs de la condition propre au type de sonde.
private struct MonConditionFields: View {
    @Binding var probe: MonProbe

    var body: some View {
        switch probe.kind {
        case .ping:
            HStack(spacing: 8) {
                Text("Port TCP de repli").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                MonInput(placeholder: "aucun", text: port($probe.fallbackPort), mono: true)
                    .frame(width: 80)
                Text("si l’ICMP est muet").font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        case .tcp:
            note("Port attendu\u{00A0}: ouvert (port indiqué dans la cible).")
        case .http:
            HStack(spacing: 6) {
                labeled("Code") { MonInput(placeholder: "200", text: int($probe.expectedStatus), mono: true).frame(width: 52) }
                labeled("Mot-clé") { MonInput(placeholder: "facultatif", text: text($probe.keyword)) }
                labeled("Cert. < j") { MonInput(placeholder: "—", text: int($probe.certificateDays), mono: true).frame(width: 52) }
            }
        case .dns:
            HStack(spacing: 6) {
                labeled("Serveur") { MonInput(placeholder: "système", text: text($probe.dnsServer), mono: true) }
                labeled("Réponse attendue") { MonInput(placeholder: "toute adresse", text: text($probe.dnsExpected), mono: true) }
            }
        case .snmp:
            VStack(alignment: .leading, spacing: 6) {
                MonInput(placeholder: "OID (1.3.6.1.2.1.1.3.0)", text: text($probe.snmpOID), mono: true)
                HStack(spacing: 6) {
                    Text("Alerte si").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                    MonMenuField(title: probe.snmpComparison?.symbol ?? "—") {
                        Button("Aucune comparaison") { probe.snmpComparison = nil }
                        ForEach(MonComparison.allCases) { item in
                            Button(item.symbol) { probe.snmpComparison = item }
                        }
                    }
                    .frame(width: 64)
                    MonInput(placeholder: "limite", text: double($probe.snmpLimit), mono: true)
                    MonInput(placeholder: "unité", text: text($probe.snmpUnit))
                        .frame(width: 64)
                }
                Text("Communauté SNMP v2c lue dans Réglages › Identifiants.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        case .switchPort:
            HStack(spacing: 8) {
                Text("Port attendu").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                MonInput(placeholder: "appris au premier passage", text: text($probe.expectedLocation), mono: true)
            }
        case .newDevices:
            note("Alerte à chaque nouvelle adresse MAC vue par le Scanner sur la plage"
                 + (probe.knownMACs.map { " (\($0.count) connues)" } ?? " (base apprise au premier passage)") + ".")
        case .cpu, .memory, .portLoad:
            MonResourceConditionFields(probe: $probe)
        case .onlineService:
            MonServiceConditionFields(probe: $probe)
        case .fortiAPOffline:
            note("Alerte quand la FortiGate du site voit la borne déconnectée («\u{00A0}*\u{00A0}»\u{00A0}: toutes les bornes lues). La FortiGate est relue au plus à chaque intervalle, en lecture seule.")
        case .fortiAPOverload:
            MonFortiAPConditionFields(probe: $probe)
        case .dhcpScope:
            MonDHCPScopeConditionFields(probe: $probe)
        case .vpnTunnel, .wanLink:
            MonWANConditionFields(probe: $probe)
        case .linkSaturated, .heavyDevice, .newThreat:
            MonTrafficConditionFields(probe: $probe)
        case .licenseExpiring, .firmwareOutdated:
            MonFirmwareConditionFields(probe: $probe)
        case .syslogSeverity, .trapReceived:
            MonLogConditionFields(probe: $probe)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.small)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
            content()
        }
    }

    private func text(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" },
                set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func int(_ value: Binding<Int?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(String.init) ?? "" },
                set: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    value.wrappedValue = trimmed.isEmpty ? nil : Int(trimmed) ?? value.wrappedValue
                })
    }

    private func port(_ value: Binding<UInt16?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(String.init) ?? "" },
                set: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    value.wrappedValue = trimmed.isEmpty ? nil : UInt16(trimmed).flatMap { $0 > 0 ? $0 : nil } ?? value.wrappedValue
                })
    }

    private func double(_ value: Binding<Double?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(MonFormat.number) ?? "" },
                set: { text in
                    let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                    value.wrappedValue = cleaned.isEmpty ? nil : Double(cleaned) ?? value.wrappedValue
                })
    }
}

// MARK: - Champs

/// Champ de saisie du croquis (blanc, bordure grise, rayon 6).
struct MonInput: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var font: Font? = nil
    var height: CGFloat = 30

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            .textFieldStyle(.plain)
            .font(font ?? (mono ? Theme.mono(12) : Theme.small))
            .foregroundStyle(Theme.text)
            .autocorrectionDisabled()
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Liste déroulante du croquis : libellé, chevrons à droite, bordure grise.
struct MonMenuField<Items: View>: View {
    let title: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 4) {
                Text(title).font(Theme.small).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Groupe encadré avec sa légende en petites majuscules (fieldset du croquis).
struct MonFieldset<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .overlay(alignment: .topLeading) {
                MonHeading(title)
                    .padding(.horizontal, 4)
                    .background(Theme.panel)
                    .offset(x: 8, y: -7)
            }
            .padding(.top, 4)
    }
}

/// Bouton « Supprimer » : contour gris, fond rouge pâle au clic.
struct MonDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyMedium)
            .padding(.horizontal, 12)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(configuration.isPressed ? Color(light: 0xFEF2F2, dark: 0x501B1B) : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .strokeBorder(configuration.isPressed ? Color(light: 0xFCA5A5, dark: 0x822B2B) : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
    }
}

/// Sonde « Borne surchargée » (note 27) : clients par radio et utilisation du canal. Le texte saisi
/// est gardé tel quel (champ vide pendant la frappe) et appliqué au seuil dès qu'il est valide.
private struct MonFortiAPConditionFields: View {
    @Binding var probe: MonProbe
    @State private var clientsText: String?
    @State private var utilizationText: String?

    var body: some View {
        let t = probe.wifiThresholds ?? .standard
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Plus de").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                MonInput(placeholder: "30", text: Binding(get: { clientsText ?? String(t.maxClientsPerRadio) }, set: { text in
                    clientsText = text
                    guard let v = Int(text.trimmingCharacters(in: .whitespaces)), v > 0 else { return }
                    var next = probe.wifiThresholds ?? .standard
                    next.maxClientsPerRadio = min(500, v)
                    probe.wifiThresholds = next
                }), mono: true)
                .frame(width: 52)
                Text("clients par radio").font(Theme.small).foregroundStyle(Theme.text)
            }
            HStack(spacing: 6) {
                Text("ou canal occupé à plus de").font(Theme.small).foregroundStyle(Theme.text)
                MonInput(placeholder: "70", text: Binding(get: { utilizationText ?? MonFormat.number(t.maxChannelUtilization) }, set: { text in
                    utilizationText = text
                    guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), v > 0 else { return }
                    var next = probe.wifiThresholds ?? .standard
                    next.maxChannelUtilization = min(100, v)
                    probe.wifiThresholds = next
                }), mono: true)
                .frame(width: 52)
                Text("%").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
            }
            .onChange(of: probe.id) { _, _ in
                clientsText = nil
                utilizationText = nil
            }
            Text("D’après la dernière lecture Wi-Fi de la FortiGate (relue au plus à chaque intervalle).")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
