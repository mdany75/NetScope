import NetScopeCore
import SwiftUI

/// Formulaire « Saisir un appareil à la main » de l'écran Appareil : IP (obligatoire), nom, MAC
/// (fabricant déduit), type et notes. Un nom DNS n'est résolu que sur clic « Résoudre ».
struct DeviceManualForm: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: DeviceLookupModel
    @FocusState private var ipFocused: Bool

    private var form: DeviceManualDraft { model.form }

    /// Appareil du Scanner déjà à cette IP (la fiche saisie serait cachée par la sienne).
    private var scanned: Device? {
        guard let ip = form.parsedIP else { return nil }
        return state.devices.first { $0.ip == ip }
    }

    private var canOpen: Bool { form.parsedIP != nil && form.macProblem == nil && scanned == nil }

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Saisir un appareil à la main").font(Theme.panelTitle)
                        Text("Pour un appareil que le Scanner n’a pas vu. La fiche s’ouvre à part des résultats du Scanner\u{00A0}; un scan qui le verra la rattachera (même MAC, sinon même IP), en gardant le nom et les notes.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button { model.formShown = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.ghost)
                        .help("Fermer le formulaire")
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow(alignment: .top) {
                        ipField
                        labeled("Nom") {
                            TextField("Nom", text: $model.form.name, prompt: Text("Ex. Mini PC salle de conférence (facultatif)"))
                                .labelsHidden().textFieldStyle(.roundedBorder)
                                .onSubmit(submit)
                        }
                    }
                    GridRow(alignment: .top) {
                        macField
                        labeled("Type d’appareil") {
                            Picker("Type d’appareil", selection: $model.form.type) {
                                ForEach(DeviceType.allCases, id: \.self) { Label($0.label, systemImage: $0.symbolName).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                    GridRow {
                        labeled("Notes (facultatives)") {
                            TextEditor(text: $model.form.notes)
                                .font(Theme.small)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .frame(height: 54)
                                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
                        }
                        .gridCellColumns(2)
                    }
                }

                if let scanned {
                    HStack(spacing: 8) {
                        Label("\(scanned.ip.description) est déjà dans le Scanner\u{00A0}: «\u{00A0}\(scanned.displayName)\u{00A0}».", systemImage: "info.circle")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Ouvrir sa fiche") {
                            model.formShown = false
                            model.query = ""
                            state.showDevice(scanned.id)
                        }
                        .buttonStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text("Rien n’est envoyé sur le réseau tant que vous ne lancez pas un outil de la fiche.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Annuler") { model.formShown = false }.buttonStyle(.secondary)
                    Button { submit() } label: { Label("Ouvrir la fiche", systemImage: Screen.appareil.symbol) }
                        .buttonStyle(.primary)
                        .disabled(!canOpen)
                }
            }
        }
        .onAppear { if form.ip.isEmpty { ipFocused = true } }
    }

    private func submit() {
        guard canOpen else { return }
        model.openForm(state)
    }

    // MARK: Champs

    private var ipField: some View {
        labeled("Adresse IP", required: true, invalid: ipMessage?.isError == true) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Adresse IP", text: $model.form.ip, prompt: Text("Ex. 10.182.122.160, ou un nom DNS"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .font(Theme.mono(12))
                        .focused($ipFocused)
                        .onSubmit(submit)
                    if case .hostname = form.ipEntry {
                        Button {
                            model.resolve()
                        } label: {
                            if form.isResolving {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Résoudre", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.secondary)
                        .disabled(form.isResolving)
                        .help("Chercher l’adresse IPv4 de ce nom (requête DNS)")
                    }
                }
                if let message = ipMessage {
                    Text(message.text)
                        .font(Theme.caption)
                        .foregroundStyle(message.isError ? Theme.critical : Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Aide ou erreur sous le champ IP.
    private var ipMessage: (text: String, isError: Bool)? {
        if let error = form.resolveError { return (error, true) }
        switch form.ipEntry {
        case .empty: return ("Obligatoire\u{00A0}: tous les outils de la fiche travaillent sur cette adresse.", false)
        case .ip:
            if let host = form.resolvedHostname { return ("Résolu depuis «\u{00A0}\(host)\u{00A0}».", false) }
            return nil
        case .hostname: return ("Nom DNS\u{00A0}: «\u{00A0}Résoudre\u{00A0}» cherche son adresse (aucune requête sans votre clic).", false)
        case .mac, .ambiguous: return ("C’est une adresse MAC\u{00A0}: mettez-la dans le champ MAC, l’IP est obligatoire.", true)
        case .invalid(let reason): return (reason, true)
        }
    }

    private var macField: some View {
        labeled("Adresse MAC (facultative)", invalid: form.macProblem != nil) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Adresse MAC", text: $model.form.mac, prompt: Text("Ex. 94:DD:F8:18:15:7D, 94dd.f818.157d"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .onSubmit(submit)
                if let problem = form.macProblem {
                    Text(problem).font(Theme.caption).foregroundStyle(Theme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let mac = form.parsedMAC {
                    Text("\(mac.formatted(.upperColon)) · fabricant\u{00A0}: \(form.vendorLabel ?? OUIDatabase.unknownLabel)")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text("Sert au Wake-on-LAN et au rattachement par un scan.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func labeled<Content: View>(_ label: String, required: Bool = false, invalid: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(label)
                if required { Text("*").foregroundStyle(Theme.critical) }
            }
            .font(Theme.captionSemibold)
            .foregroundStyle(invalid ? Theme.critical : Theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bandeau d'une fiche ouverte hors Scanner : origine, vérification par ping (sur clic), ajout à
/// l'inventaire et oubli de la saisie.
struct DeviceManualBanner: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var inventory = InvModel.shared
    let entry: ManualDeviceEntry
    @State private var isChecking = false
    @State private var checkError: String?
    @State private var addingToInventory = false

    /// Fiche d'inventaire du site actif pour cet appareil (même MAC, sinon même IP).
    private var record: InvRecord? {
        if let mac = entry.mac {
            if let record = inventory.store.record(InventoryStore.key(mac: mac)) { return record }
            // Fiche ajoutée à la main (clé « man:… ») : cherchée par sa MAC.
            if let record = inventory.store.records.values.first(where: { $0.mac == mac }) { return record }
        }
        return inventory.store.record(forIP: entry.ip)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Une ligne si tout tient, sinon les boutons sous le texte.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    info
                    Spacer(minLength: 8)
                    HStack(spacing: 8) { buttons }
                }
                VStack(alignment: .leading, spacing: 8) {
                    info
                    HStack(spacing: 8) { buttons }
                }
            }
            if let checkError {
                Label(checkError, systemImage: "exclamationmark.triangle")
                    .font(Theme.caption).foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius + 2).fill(Theme.warningSoft.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius + 2).strokeBorder(Theme.warning.opacity(0.35)))
        .sheet(isPresented: $addingToInventory) {
            InvManualSheet(mode: .add(site: inventory.siteKey), prefill: draft, dismiss: { addingToInventory = false })
        }
    }

    private var info: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: entry.isTyped ? "hand.point.up.left.fill" : "tray.full")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.originLabel).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                Text(checkSummary).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button { check() } label: {
            if isChecking {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Vérification…") }
            } else {
                Label("Vérifier maintenant", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .buttonStyle(.secondary)
        .disabled(isChecking)
        .help("Un seul ping vers \(entry.ip.description) (rien n’est envoyé sans ce clic)")
        if let record {
            Button {
                state.navigate(NavDestination(.inventaire, focus: .record(site: inventory.siteKey, key: record.key)))
            } label: {
                Label("Voir dans l’inventaire", systemImage: Screen.inventaire.symbol)
            }
            .buttonStyle(.secondary)
        } else {
            Button { addingToInventory = true } label: {
                Label("Ajouter à l’inventaire", systemImage: "plus.rectangle.on.folder")
            }
            .buttonStyle(.secondary)
        }
        Button { state.forgetManual(entry) } label: {
            Label(entry.isTyped ? "Oublier cette saisie" : "Fermer cette fiche", systemImage: "xmark.circle")
        }
        .buttonStyle(.secondary)
        .help(entry.isTyped ? "Retirer cet appareil saisi (ses notes restent au site)" : "Fermer la fiche reprise")
    }

    /// « Jamais vérifié », « Répond en 3,4 ms · vérifié il y a 2 min »…
    private var checkSummary: String {
        let created = "Ouvert \(ToolText.relative(entry.created))"
        guard let check = entry.lastCheck else {
            return "\(created) · pas encore vérifié\u{00A0}: «\u{00A0}Vérifier maintenant\u{00A0}» envoie un ping à \(entry.ip)."
        }
        let when = ToolText.relative(check.date)
        if let latency = check.latencyMs {
            return "\(created) · répond au ping en \(ToolFormat.milliseconds(latency)) (vérifié \(when))"
        }
        return "\(created) · ne répond pas au ping (vérifié \(when))\u{00A0}; il peut bloquer l’ICMP."
    }

    /// Ping unique vers l'IP de la fiche, seulement sur clic.
    private func check() {
        isChecking = true
        checkError = nil
        let ip = entry.ip
        let id = entry.id
        Task {
            let latency: Double?
            do {
                let pinger = try ICMPPinger()
                latency = await pinger.ping(ip, timeout: .seconds(2))
            } catch {
                checkError = "Ping impossible\u{00A0}: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                isChecking = false
                return
            }
            if var current = state.manualDevices.first(where: { $0.id == id }) {
                current.lastCheck = ManualDeviceEntry.Check(date: Date(), latencyMs: latency)
                state.updateManual(current)
            }
            isChecking = false
        }
    }

    /// Brouillon de la feuille « Ajouter un appareil » de l'Inventaire.
    private var draft: InvManualDraft {
        let device = entry.device
        return InvManualDraft(name: entry.name.isEmpty ? (device.hostnameLabel ?? "") : entry.name, ip: entry.ip, mac: entry.mac,
                              vendor: device.vendor ?? entry.mac.flatMap { OUIDatabase.builtIn.vendor(for: $0) } ?? "",
                              type: entry.type, switchName: device.switchName ?? "", switchPort: device.switchPort ?? "",
                              notes: DeviceNotesStore.shared.note(for: device))
    }
}
