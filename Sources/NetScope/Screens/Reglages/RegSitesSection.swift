import NetScopeCore
import SwiftUI

/// Réglages › Sites et plages : édition de `AppState.ranges` (ajout, suppression, nom, VLAN,
/// inclusion au scan), avec validation par IPRange.
struct RegSitesSection: View {
    @EnvironmentObject private var state: AppState
    @State private var newText = ""
    @State private var newLabel = ""
    @State private var newVLAN = ""
    @State private var error: String?
    @State private var detectOn = true
    @StateObject private var table = RegRangeTable.makeModel()

    var body: some View {
        RegPanel(title: "Sites et plages",
                 subtitle: "Plages enregistrées pour le Scanner. Le regroupement par site (choisi selon la passerelle détectée) viendra bientôt.",
                 accessory: {
                     Button {} label: { Label("Nouveau site", systemImage: "plus") }
                         .buttonStyle(.secondary)
                         .regDisabled(true)
                         .help("Plusieurs sites : bientôt")
                 }, content: {
                     siteTabs
                     tiles.padding(.top, 14)
                     HStack(alignment: .center) {
                         Text("PLAGES DU SITE")
                             .font(Theme.captionSemibold).kerning(0.55).foregroundStyle(Theme.textSecondary)
                         Spacer(minLength: 8)
                         StandardColumnsMenu(model: table)
                     }
                     .padding(.top, 12).padding(.bottom, 6)
                     rangeTable
                     addForm.padding(.top, 10)
                     HStack(alignment: .top, spacing: 14) {
                         soonBox(title: "Plages exclues",
                                 text: "Jamais sondées, même si elles font partie d’une plage du site (passerelle, contrôleur de domaine…).")
                         soonBox(title: "Détection automatique au branchement",
                                 text: "Associer le site par l’IP et la MAC de la passerelle, puis proposer le scan de ses plages.")
                     }
                     .padding(.top, 16)
                 })
    }

    // MARK: En-tête

    private var siteTabs: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 11))
                Text(state.activeInterface.map { "Réseau \($0.kind.label)" } ?? "Ce Mac")
                Text("\(state.ranges.count)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accentStrong)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Theme.accentSoft))
            .overlay(Capsule().strokeBorder(Theme.accent))
            Spacer()
        }
    }

    private var activeRanges: [ScanRangeConfig] { state.ranges.filter(\.isEnabled) }

    private var totalAddresses: Int {
        activeRanges.reduce(0) { $0 + ((try? $1.parsed().count) ?? 0) }
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            RegTile("Réseau détecté", state.activeInterface.map { $0.subnet.description } ?? "Aucune interface active", mono: true)
            RegTile("Interface", state.activeInterface.map { "\($0.name) · \($0.kind.label)" } ?? "—", mono: true)
            RegTile("Passerelle de référence", state.activeInterface?.gateway?.description ?? "Non lue", mono: true)
            RegTile("Total à scanner", "\(RegFormat.count(totalAddresses)) adresses · \(activeRanges.count) active(s)", mono: true)
        }
    }

    // MARK: Tableau

    private var rangeTable: some View {
        VStack(spacing: 0) {
            if !state.ranges.isEmpty {
                RegRangeTable(table: table)
            } else {
                Text("Aucune plage. Ajoutez-en une ci-dessous ou utilisez « Mon réseau » pour reprendre celui de l’interface active.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(18)
                    .frame(maxWidth: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    // MARK: Ajout

    private var preview: String {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return "Formats acceptés : 10.0.0.0/24, 10.0.0.1-10.0.0.50, 10.0.0.1-50, liste 10.0.0.9, 10.0.0.12 — au plus \(RegFormat.count(Int(IPRange.maxAddresses))) adresses."
        }
        do {
            let range = try IPRange(parsing: text)
            let kind = ScanRangeConfig(text: text, label: "").kindLabel
            return "\(kind) · \(RegFormat.count(range.count)) adresse(s) à sonder"
        } catch {
            return error.localizedDescription
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                RegField(label: "Plage (CIDR, début-fin ou IP)") {
                    RegTextField(placeholder: "172.16.0.0/22 ou 10.10.0.1-10.10.0.50", text: $newText, mono: true)
                        .onSubmit(add)
                }
                .frame(maxWidth: .infinity)
                RegField(label: "Nom") {
                    RegTextField(placeholder: "Ex. Production", text: $newLabel)
                }
                .frame(width: 200)
                RegField(label: "VLAN") {
                    RegTextField(placeholder: "1–4094", text: $newVLAN, mono: true)
                }
                .frame(width: 90)
                Button(action: add) { Label("Ajouter la plage", systemImage: "plus") }
                    .buttonStyle(.secondary)
                Button(action: addDetected) { Label("Mon réseau", systemImage: "scope") }
                    .buttonStyle(.secondary)
                    .regDisabled(state.activeInterface == nil)
                    .help("Ajoute le réseau de l’interface active")
            }
            Text(preview).font(Theme.small).foregroundStyle(Theme.textSecondary)
            if let error {
                Text(error)
                    .font(Theme.small).foregroundStyle(Theme.critical)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.criticalSoft))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius)
            .strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespaces)
        do {
            _ = try IPRange(parsing: text)
        } catch {
            self.error = "Plage invalide : « \(text.isEmpty ? "vide" : text) ». \(error.localizedDescription)"
            return
        }
        let vlanText = newVLAN.trimmingCharacters(in: .whitespaces)
        var vlan: Int?
        if !vlanText.isEmpty {
            guard let value = Int(vlanText), (1...4094).contains(value) else {
                error = "VLAN invalide : saisir un nombre de 1 à 4094."
                return
            }
            vlan = value
        }
        if state.ranges.contains(where: { $0.text.replacingOccurrences(of: " ", with: "") == text.replacingOccurrences(of: " ", with: "") }) {
            error = "Cette plage est déjà enregistrée."
            return
        }
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        state.ranges.append(ScanRangeConfig(text: text, label: label.isEmpty ? "Nouvelle plage" : label, vlan: vlan))
        newText = ""
        newLabel = ""
        newVLAN = ""
        error = nil
    }

    private func addDetected() {
        guard let interface = state.activeInterface else { return }
        let subnet = interface.subnet.prefix < 16 ? Subnet(address: interface.address, prefix: 24) : interface.subnet
        newText = subnet.description
        if newLabel.isEmpty { newLabel = interface.kind == .wifi ? "Wi-Fi" : "Réseau local" }
        add()
    }

    private func soonBox(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(Theme.captionSemibold).kerning(0.55).foregroundStyle(Theme.textSecondary)
                Chip(text: "Bientôt")
            }
            Text(text).font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

