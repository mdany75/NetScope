import NetScopeCore
import SwiftUI

/// Calculateur IPv6 (0.31.0), dans le calculateur de sous-réseau dès que la saisie contient
/// « : » : préfixe, plage, nombre d'adresses, formes courte et complète, EUI-64 et découpage.
struct IPv6CalculatorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolSubnetModel
    @ObservedObject var store: ToolStore
    @ObservedObject private var ipv6 = IPv6Model.shared

    private static let maxRows = 16
    private static let lengths = [32, 40, 44, 48, 52, 56, 60, 62, 64, 72, 80, 96, 112, 120, 124, 126, 127, 128]

    var body: some View {
        let parsed = Result { try IPv6Prefix(parsing: model.cidr) }
        VStack(alignment: .leading, spacing: 16) {
            inputs(current: try? parsed.get())
            quickPrefixes
            switch parsed {
            case .failure(let error):
                ToolNotice(tone: .critical, title: "Entrée invalide",
                           message: (error as? LocalizedError)?.errorDescription ?? "Format attendu\u{00A0}: 2001:db8:a00::/48.")
            case .success(let prefix):
                notice(prefix)
                ToolCellGrid(cells: cells(prefix), columns: 3)
                eui64Block(prefix)
                splitBlock(prefix)
            }
        }
    }

    // MARK: Saisie

    private func inputs(current: IPv6Prefix?) -> some View {
        let length = current?.length ?? 64
        return ToolAdaptiveRow(spacing: 12) {
            ToolLabeledField(label: "Préfixe IPv6") {
                ToolTextField(placeholder: "2001:db8:a00::/48", text: $model.cidr, invalid: current == nil, height: 36)
                    .frame(minWidth: 260)
            }
            ToolLabeledField(label: "Longueur") {
                HStack(spacing: 4) {
                    Button("−") { setLength(max(0, length - 1)) }
                        .buttonStyle(.secondary)
                        .help("Préfixe plus court (bloc plus grand)")
                    Menu {
                        ForEach(Self.lengths, id: \.self) { value in
                            Button("/\(value) · \(IPv6Prefix(address: .unspecified, length: value).usage)") { setLength(value) }
                        }
                    } label: {
                        Text("/\(length)").font(Theme.mono(13))
                    }
                    .menuStyle(.button)
                    .controlSize(.large)
                    .frame(width: 90)
                    Button("+") { setLength(min(128, length + 1)) }
                        .buttonStyle(.secondary)
                        .help("Préfixe plus long (bloc plus petit)")
                }
            }
            .fixedSize()
        }
    }

    private func setLength(_ length: Int) {
        let head = model.cidr.split(separator: "/").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "2001:db8::"
        model.cidr = "\(head)/\(length)"
    }

    private var quickPrefixes: some View {
        var list: [String] = []
        if let routed = ipv6.status.routedPrefix { list.append(routed.description) }
        for address in ipv6.status.addresses where address.address.scope == .uniqueLocal {
            list.append(IPv6Prefix(address: address.address, length: address.prefixLength).description)
        }
        list += ["2001:db8:a00::/48", "fd00::/8", "fe80::/64"]
        var seen = Set<String>()
        let unique = list.filter { seen.insert($0).inserted }.prefix(5)
        let current = model.cidr.trimmingCharacters(in: .whitespaces)
        let ipv4 = state.activeInterface?.subnet.description ?? "10.182.122.0/24"
        return ToolFlowLayout(spacing: 6) {
            Text("Préfixes\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(height: 28)
            ForEach(Array(unique), id: \.self) { text in
                ToolChoiceChip(label: text, isSelected: text == current) { model.cidr = text }
            }
            ToolChoiceChip(label: "IPv4 \(ipv4)", isSelected: false) { model.cidr = ipv4 }
        }
    }

    // MARK: Résultats

    private func notice(_ prefix: IPv6Prefix) -> some View {
        let known = state.devices.filter { ($0.ipv6 ?? []).contains(where: prefix.contains) }
        var parts: [String] = []
        if known.isEmpty {
            parts.append("Aucun appareil connu avec une adresse dans ce préfixe.")
        } else {
            parts.append(known.count == 1 ? "1 appareil connu dans ce préfixe" : "\(known.count) appareils connus dans ce préfixe")
        }
        if ipv6.status.addresses.contains(where: { prefix.contains($0.address) }) {
            parts.append("ce Mac y a une adresse (\(ipv6.status.interface ?? "interface active"))")
        }
        return ToolNotice(tone: .accent, message: parts.joined(separator: " · "))
    }

    private func cells(_ prefix: IPv6Prefix) -> [ToolCell] {
        let network = prefix.network
        let entered = prefix.entered != network ? "adresse saisie \(prefix.entered) ramenée au préfixe" : "préfixe exact"
        let scope = network.scope
        return [
            ToolCell(key: "Préfixe", value: prefix.description, detail: entered),
            ToolCell(key: "Première adresse", value: network.description, detail: "adresse du sous-réseau (routeur anycast)"),
            ToolCell(key: "Dernière adresse", value: prefix.last.description, detail: "pas de broadcast en IPv6"),
            ToolCell(key: "Adresses", value: prefix.addressCountText, detail: "\(prefix.hostBits) bits d’interface"),
            ToolCell(key: "Réseaux /64", value: prefix.length <= 64 ? IPv6Prefix.powerText(64 - prefix.length) : "—",
                     detail: prefix.usage),
            ToolCell(key: "Type d’adresse", value: scope.label, detail: scope.block),
            ToolCell(key: "Forme courte", value: prefix.entered.description, detail: "RFC 5952 (canonique)"),
            ToolCell(key: "Forme complète", value: prefix.entered.expanded, detail: "huit groupes de quatre chiffres"),
            ToolCell(key: "Identifiant d’interface", value: prefix.entered.embeddedMAC.map { "EUI-64 · \($0.formatted(.upperColon))" } ?? "—",
                     detail: prefix.entered.embeddedMAC == nil ? "aléatoire, opaque ou fixé à la main" : "MAC d’origine (ff:fe au milieu)"),
        ]
    }

    // MARK: EUI-64

    private func eui64Block(_ prefix: IPv6Prefix) -> some View {
        let mac = MACAddress(model.eui64MAC.trimmingCharacters(in: .whitespaces))
        let base = IPv6Prefix(address: prefix.network, length: 64).network
        return VStack(alignment: .leading, spacing: 10) {
            Text("Adresse EUI-64 d’une MAC").font(Theme.bodySemibold)
            ToolAdaptiveRow(spacing: 12) {
                ToolLabeledField(label: "Adresse MAC") {
                    ToolTextField(placeholder: "94:DD:F8:18:15:7D", text: $model.eui64MAC,
                                  invalid: !model.eui64MAC.isEmpty && mac == nil, height: 32)
                        .frame(minWidth: 180)
                }
                if let mac {
                    VStack(alignment: .leading, spacing: 4) {
                        resultLine("Dans \(IPv6Prefix(address: base, length: 64))", IPv6Address.eui64(mac: mac, prefix: base).description)
                        resultLine("Lien local", IPv6Address.eui64(mac: mac).description)
                        resultLine("Identifiant", String(format: "%016llx", IPv6Address.interfaceIdentifier(mac: mac))
                            .enumerated().map { $0.offset > 0 && $0.offset % 4 == 0 ? ":\($0.element)" : "\($0.element)" }.joined())
                    }
                }
            }
            Text("Bit universel/local (7ᵉ bit) inversé et ff:fe inséré au milieu (RFC 4291). Les postes récents utilisent plutôt un identifiant opaque (RFC 7217) ou temporaire.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func resultLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(1)
        }
    }

    // MARK: Découpage

    private func splitBlock(_ prefix: IPv6Prefix) -> some View {
        let p = prefix.length
        let choices = Array(Set([p + 4, p + 8, p + 16, 48, 56, 60, 64].filter { $0 > p && $0 <= 128 })).sorted().prefix(7)
        let chosen = choices.contains(model.splitLength6) ? model.splitLength6 : (choices.contains(64) ? 64 : (choices.first ?? p))
        let pieces = prefix.subnets(newLength: chosen, limit: Self.maxRows)
        let summary = choices.isEmpty ? "Un /128 ne peut pas être découpé."
            : "\(prefix.subnetCountText(newLength: chosen)) sous-réseaux /\(chosen) · \(IPv6Prefix.powerText(128 - chosen)) adresses chacun"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Découpage en sous-réseaux").font(Theme.bodySemibold)
            Text(summary).font(Theme.small).foregroundStyle(Theme.textSecondary)
            if !choices.isEmpty {
                ToolFlowLayout(spacing: 4) {
                    ForEach(Array(choices), id: \.self) { value in
                        ToolChoiceChip(label: "/\(value) (\(prefix.subnetCountText(newLength: value)))", isSelected: value == chosen) {
                            model.splitLength6 = value
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(Theme.mono(11)).foregroundStyle(Theme.textTertiary).frame(width: 24, alignment: .trailing)
                            Text(piece.description).font(Theme.mono(12, weight: .semibold)).foregroundStyle(Theme.text)
                                .lineLimit(1).frame(minWidth: 200, alignment: .leading)
                            Text("\(piece.network.description) – \(piece.last.description)").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                    }
                }
                HStack {
                    Text(pieces.count >= Self.maxRows ? "Les \(Self.maxRows) premiers sous-réseaux." : "")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Copier la liste") {
                        ToolActions.copy(pieces.map(\.description).joined(separator: "\n"))
                        store.record(command: "ipcalc \(prefix) --split \(chosen)")
                    }
                    .buttonStyle(.ghost)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}
