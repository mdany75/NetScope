import NetScopeCore
import SwiftUI

/// Ce que la feuille d'ajout à la main fait.
enum InvManualMode: Identifiable, Hashable {
    /// Nouvel appareil dans ce site.
    case add(site: String)
    /// Fiche ajoutée à la main à modifier.
    case edit(site: String, key: String)

    var id: String {
        switch self {
        case .add(let site): return "ajout|" + site
        case .edit(let site, let key): return "modif|" + site + "|" + key
        }
    }

    var site: String {
        switch self {
        case .add(let site), .edit(let site, _): return site
        }
    }
}

/// Feuille « Ajouter un appareil » (note 10) : appareil absent des scans (imprimante hors réseau,
/// équipement éteint, matériel en stock), tous les champs ; il est rapproché automatiquement d'un
/// appareil que le scan de ce site verra ensuite (même MAC, sinon même IP), sans perdre ces champs.
struct InvManualSheet: View {
    @ObservedObject private var model = InvModel.shared
    @ObservedObject private var sites = SiteModel.shared
    let mode: InvManualMode
    /// Dessinée dans la page (captures) plutôt qu'en feuille.
    var inline = false
    /// Champs préremplis d'un nouvel appareil (fiche saisie dans l'écran Appareil).
    var prefill: InvManualDraft? = nil
    /// Clé de la fiche créée ou modifiée (et son site).
    var onDone: (String, String) -> Void = { _, _ in }
    let dismiss: () -> Void

    @State private var site = ""
    @State private var name = ""
    @State private var ip = ""
    @State private var mac = ""
    @State private var vendor = ""
    @State private var type: DeviceType = .inconnu
    @State private var location = ""
    @State private var wallJack = ""
    @State private var switchName = ""
    @State private var switchPort = ""
    @State private var owner = ""
    @State private var asset = ""
    @State private var tags = ""
    @State private var notes = ""
    @State private var error: String?
    @State private var loaded = false

    private var isEdit: Bool { if case .edit = mode { return true } else { return false } }

    /// Fiche modifiée, si elle existe encore.
    private var editedRecord: InvRecord? {
        guard case .edit(let site, let key) = mode else { return nil }
        return model.inventory(for: site).record(key)
    }

    /// IP et MAC verrouillées : fiche déjà rapprochée d'un appareil scanné (elles viennent du scan).
    private var addressLocked: Bool { editedRecord.map { !$0.isAwaitingScan } ?? false }

    private var parsedIP: IPv4Address? { IPv4Address(ip.trimmingCharacters(in: .whitespaces)) }
    private var parsedMAC: MACAddress? { MACAddress(mac.trimmingCharacters(in: .whitespaces)) }
    private var ipInvalid: Bool { !ip.trimmingCharacters(in: .whitespaces).isEmpty && parsedIP == nil }
    private var macInvalid: Bool { !mac.trimmingCharacters(in: .whitespaces).isEmpty && parsedMAC == nil }

    private var draft: InvManualDraft {
        InvManualDraft(name: name, ip: parsedIP, mac: parsedMAC, vendor: vendor, type: type, location: location,
                       wallJack: wallJack, switchName: switchName, switchPort: switchPort, owner: owner,
                       assetNumber: asset, notes: notes,
                       tags: tags.split(whereSeparator: { $0 == "," || $0 == ";" }).map { String($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEdit ? "Modifier l’appareil ajouté à la main" : "Ajouter un appareil à la main").font(Theme.panelTitle)
                    Text(isEdit && addressLocked
                         ? "Déjà rapproché d’un appareil scanné\u{00A0}: son IP, sa MAC, son switch et son port viennent du scan."
                         : "Appareil absent des scans (hors réseau, éteint, en stock). Il sera rapproché de l’appareil que le scan de ce site verra ensuite (même MAC, sinon même IP), sans perdre ces champs.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Site").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                        Picker("Site", selection: $site) {
                            ForEach(siteChoices, id: \.key) { Text($0.name).tag($0.key) }
                        }
                        .labelsHidden()
                        .disabled(isEdit)
                    }
                    InvField(label: "Nom", text: $name, placeholder: "Ex. Imprimante d’étiquettes quai 2")
                }
                GridRow {
                    field("Adresse IP", text: $ip, placeholder: "Ex. 10.182.122.50 (facultatif)", invalid: ipInvalid, mono: true)
                        .disabled(addressLocked)
                    field("Adresse MAC", text: $mac, placeholder: "Ex. 00:1B:44:11:3A:B7 (facultatif)", invalid: macInvalid, mono: true)
                        .disabled(addressLocked)
                }
                GridRow {
                    InvField(label: "Fabricant", text: $vendor, placeholder: "Ex. Zebra")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Type").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                        Picker("Type", selection: $type) {
                            ForEach(DeviceType.ordered, id: \.self) { Label($0.label, systemImage: $0.symbolName).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                GridRow {
                    InvField(label: "Local", text: $location, placeholder: "Ex. 1er étage · Quai 2")
                    InvField(label: "Prise murale", text: $wallJack, placeholder: "Ex. Q2-04")
                }
                GridRow {
                    InvField(label: "Switch", text: $switchName, placeholder: "Ex. SW-QUAI-01")
                        .disabled(addressLocked)
                    InvField(label: "Port", text: $switchPort, placeholder: "Ex. 1/12")
                        .disabled(addressLocked)
                }
                GridRow {
                    InvField(label: "Responsable", text: $owner, placeholder: "Ex. Expédition")
                    InvField(label: "N° d’actif", text: $asset, placeholder: "Ex. INV-00512")
                }
                GridRow {
                    InvField(label: "Étiquettes (séparées par des virgules)", text: $tags, placeholder: "Ex. Stock, Quai")
                        .gridCellColumns(2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(Theme.captionSemibold).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $notes)
                    .font(Theme.small)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.borderStrong))
            }

            if let warning {
                Label(warning, systemImage: "info.circle")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.small).foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Marqué «\u{00A0}Ajouté à la main\u{00A0}» dans l’inventaire de ce site seulement.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Annuler", action: dismiss).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button(isEdit ? "Enregistrer" : "Ajouter à l’inventaire", action: save)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isUsable || ipInvalid || macInvalid)
            }
        }
        .padding(20)
        .frame(width: 600)
        .background(inline ? Theme.panel : Color.clear)
        .onAppear(perform: load)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, invalid: Bool, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.captionSemibold).foregroundStyle(invalid ? Theme.critical : Theme.textSecondary)
            TextField(label, text: text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(mono ? Theme.mono(12) : Theme.body)
                .help(invalid ? "\(label) illisible" : "")
        }
    }

    private var siteChoices: [(key: String, name: String)] {
        var list = sites.sortedSites.map { (SiteFiles.key(for: $0.id), $0.displayName) }
        if !list.contains(where: { $0.0 == model.siteKey }) { list.insert((model.siteKey, sites.activeName), at: 0) }
        if !site.isEmpty, !list.contains(where: { $0.0 == site }) { list.append((site, sites.name(forKey: site))) }
        return list.map { (key: $0.0, name: $0.1) }
    }

    /// Adresse déjà prise dans ce site : avertissement, jamais un refus.
    private var warning: String? {
        guard !addressLocked, let address = parsedIP else { return nil }
        let except: String? = { if case .edit(_, let key) = mode { return key } else { return nil } }()
        guard let other = model.inventory(for: site).recordUsingIP(address, except: except) else { return nil }
        return "\(address) est aussi l’adresse de «\u{00A0}\(other.displayName)\u{00A0}» dans ce site\u{00A0}: le rapprochement par IP ne se fera que pour un appareil sans fiche."
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        site = mode.site
        guard let record = editedRecord else {
            if let prefill {
                apply(prefill)
            } else if InvManualDemo.prefills {
                let demo = InvManualDemo.draft
                name = demo.name
                ip = demo.ip?.description ?? ""
                vendor = demo.vendor
                type = demo.type
                location = demo.location
                wallJack = demo.wallJack
                owner = demo.owner
                tags = demo.tags.joined(separator: ", ")
                notes = demo.notes
            }
            return
        }
        apply(InvManualDraft(record: record))
    }

    private func apply(_ current: InvManualDraft) {
        name = current.name
        ip = current.ip?.description ?? ""
        mac = current.mac?.formatted(.upperColon) ?? ""
        vendor = current.vendor
        type = current.type
        location = current.location
        wallJack = current.wallJack
        switchName = current.switchName
        switchPort = current.switchPort
        owner = current.owner
        asset = current.assetNumber
        tags = current.tags.joined(separator: ", ")
        notes = current.notes
    }

    private func save() {
        error = nil
        switch mode {
        case .add:
            switch model.addManual(draft, site: site) {
            case .success(let key):
                model.show("Ajouté à la main dans «\u{00A0}\(sites.name(forKey: site))\u{00A0}»\u{00A0}: \(model.inventory(for: site).record(key)?.displayName ?? name)")
                dismiss()
                onDone(key, site)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        case .edit(let site, let key):
            if let failure = model.updateManual(key, draft: draft, site: site) {
                error = failure.localizedDescription
            } else {
                model.show("Fiche enregistrée\u{00A0}: \(model.inventory(for: site).record(key)?.displayName ?? name)")
                dismiss()
                onDone(key, site)
            }
        }
    }
}
