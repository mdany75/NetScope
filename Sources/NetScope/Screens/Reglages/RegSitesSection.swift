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

    private let columns: [TableHeader.Column] = [
        .init(title: "Plage", width: 190),
        .init(title: "Nom"),
        .init(title: "Format", width: 100),
        .init(title: "VLAN", width: 100),
        .init(title: "Adresses", width: 90, alignment: .trailing),
        .init(title: "Inclure au scan", width: 130),
        .init(title: "", width: 44),
    ]

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
                     Text("PLAGES DU SITE")
                         .font(Theme.captionSemibold).kerning(0.55).foregroundStyle(Theme.textSecondary)
                         .padding(.top, 16).padding(.bottom, 8)
                     table
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

    private var table: some View {
        VStack(spacing: 0) {
            TableHeader(columns: columns)
            ForEach(state.ranges) { range in
                RegRangeRow(range: range, columns: columns)
            }
            if state.ranges.isEmpty {
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

/// Une ligne du tableau des plages : nom et VLAN modifiables sur place.
private struct RegRangeRow: View {
    @EnvironmentObject private var state: AppState
    let range: ScanRangeConfig
    let columns: [TableHeader.Column]

    private var index: Int? { state.ranges.firstIndex { $0.id == range.id } }

    private var labelBinding: Binding<String> {
        Binding(get: { range.label }, set: { value in
            if let index { state.ranges[index].label = value }
        })
    }

    private var vlanBinding: Binding<String> {
        Binding(get: { range.vlan.map(String.init) ?? "" }, set: { value in
            guard let index else { return }
            let digits = value.filter(\.isNumber)
            if digits.isEmpty {
                state.ranges[index].vlan = nil
            } else if let number = Int(digits), (1...4094).contains(number) {
                state.ranges[index].vlan = number
            }
        })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { range.isEnabled }, set: { value in
            if let index { state.ranges[index].isEnabled = value }
        })
    }

    var body: some View {
        let parsed = try? range.parsed()
        HStack(spacing: 0) {
            cell(0) {
                Text(range.text).font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(parsed == nil ? Theme.critical : Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                    .help(parsed == nil ? "Plage invalide" : range.text)
            }
            cell(1) { inlineField(labelBinding, placeholder: "Nom", mono: false) }
            cell(2) { Text(range.kindLabel).font(Theme.small).foregroundStyle(Theme.textSecondary) }
            cell(3) {
                HStack(spacing: 3) {
                    Text("VLAN").font(Theme.mono(11)).foregroundStyle(Theme.neutralText).fixedSize()
                    inlineField(vlanBinding, placeholder: "?", mono: true).frame(width: 40)
                }
            }
            cell(4) {
                Text(parsed.map { RegFormat.count($0.count) } ?? "—").font(Theme.mono(12))
            }
            cell(5) { RegSwitch(isOn: enabledBinding) }
            cell(6) {
                Button {
                    state.ranges.removeAll { $0.id == range.id }
                } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Supprimer la plage \(range.text)")
            }
        }
        .frame(height: 38)
        .background(range.isEnabled ? Theme.panel : Theme.panelMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private func cell<Content: View>(_ column: Int, @ViewBuilder _ content: () -> Content) -> some View {
        let spec = columns[column]
        let view = content().padding(.horizontal, column == 0 ? 12 : 8)
        if let width = spec.width {
            view.frame(width: width, alignment: spec.alignment)
        } else {
            view.frame(maxWidth: .infinity, alignment: spec.alignment)
        }
    }

    private func inlineField(_ binding: Binding<String>, placeholder: String, mono: Bool) -> some View {
        TextField("", text: binding, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(11) : Theme.small)
            .padding(.horizontal, 4)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(mono ? Theme.neutralSoft : Color.clear))
    }
}
