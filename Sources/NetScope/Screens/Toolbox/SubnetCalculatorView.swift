import NetScopeCore
import SwiftUI

@MainActor
final class ToolSubnetModel: ObservableObject {
    @Published var cidr = "10.182.122.0/24"
    /// Préfixe de découpage choisi (corrigé s'il ne convient pas au réseau saisi).
    @Published var splitPrefix = 26
}

/// Analyse de la saisie du calculateur.
struct SubnetCalculation {
    let subnet: Subnet
    /// Adresse saisie avant le « / » (peut être un hôte du réseau).
    let entered: IPv4Address

    enum Failure: Error { case message(String) }

    static func parse(_ text: String) -> Result<SubnetCalculation, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .failure(.message("Saisir un réseau, par exemple 10.182.122.0/24.")) }
        if IPv4Address(trimmed) != nil {
            return .failure(.message("Préfixe manquant : ajoutez /xx, par exemple \(trimmed)/24."))
        }
        do {
            let subnet = try Subnet(parsing: trimmed)
            let head = trimmed.split(whereSeparator: { $0 == "/" || $0 == " " }).first.map(String.init) ?? ""
            return .success(SubnetCalculation(subnet: subnet, entered: IPv4Address(head) ?? subnet.network))
        } catch {
            return .failure(.message((error as? LocalizedError)?.errorDescription ?? "Format attendu : a.b.c.d/préfixe, par exemple 10.182.122.0/24."))
        }
    }

    /// Type d'adresse (valeur courte, précision).
    var scopeText: (String, String) {
        switch subnet.scope {
        case .privee:
            for block in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] {
                if let s = try? Subnet(parsing: block), s.contains(subnet.network) { return ("Privée", "RFC 1918 · \(block)") }
            }
            return ("Privée", "RFC 1918")
        case .publique: return ("Publique", "routable sur Internet")
        case .bouclage: return ("Bouclage", "127.0.0.0/8")
        case .liaisonLocale: return ("Lien local", "APIPA · 169.254.0.0/16")
        case .cgnat: return ("CGNAT", "RFC 6598 · 100.64.0.0/10")
        case .multicast: return ("Multidiffusion", "224.0.0.0/4")
        case .reservee: return ("Réservée", "0.0.0.0/8 ou 240.0.0.0/4")
        }
    }

    var classDetail: String {
        switch subnet.addressClass {
        case "D": return "multidiffusion"
        case "E": return "réservée"
        default: return "classe historique (avant CIDR)"
        }
    }

    /// Bits réseau et bits hôte d'une adresse, avec les points entre octets.
    static func binaryParts(_ address: IPv4Address, prefix: Int) -> (String, String) {
        let bits = Subnet.binary(address).replacingOccurrences(of: ".", with: "")
        var network = "", host = ""
        for (index, bit) in bits.enumerated() {
            let piece = (index > 0 && index % 8 == 0 ? "." : "") + String(bit)
            if index < prefix { network += piece } else { host += piece }
        }
        return (network, host)
    }
}

/// Calculateur de sous-réseau complet (croquis : bloc « CALCULATEUR DE SOUS-RÉSEAU »).
struct SubnetCalculatorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolSubnetModel
    @ObservedObject var store: ToolStore

    private static let maxRows = 16

    var body: some View {
        let parsed = SubnetCalculation.parse(model.cidr)
        VStack(alignment: .leading, spacing: 16) {
            inputs(current: try? parsed.get())
            quickRanges
            switch parsed {
            case .failure(.message(let message)):
                ToolNotice(tone: .critical, title: "Entrée invalide", message: message)
            case .success(let calculation):
                results(calculation)
            }
        }
    }

    // MARK: Saisie

    private func inputs(current: SubnetCalculation?) -> some View {
        let prefix = current?.subnet.prefix ?? 24
        return HStack(alignment: .bottom, spacing: 12) {
            ToolLabeledField(label: "Adresse CIDR") {
                ToolTextField(placeholder: "10.182.122.0/24", text: $model.cidr, invalid: current == nil, height: 36)
            }
            ToolLabeledField(label: "Préfixe") {
                HStack(spacing: 4) {
                    Button("−") { setPrefix(max(1, prefix - 1)) }
                        .buttonStyle(.secondary).frame(width: 34)
                    Menu {
                        ForEach(8...32, id: \.self) { value in
                            Button("/\(value) · \(IPv4Address.mask(prefix: value).description)") { setPrefix(value) }
                        }
                    } label: {
                        Text("/\(prefix) · \(IPv4Address.mask(prefix: prefix).description)").font(Theme.mono(13))
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 10)
                    .frame(width: 190, height: 36)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                    Button("+") { setPrefix(min(32, prefix + 1)) }
                        .buttonStyle(.secondary).frame(width: 34)
                }
            }
            .fixedSize()
        }
    }

    private func setPrefix(_ prefix: Int) {
        let head = model.cidr.split(whereSeparator: { $0 == "/" || $0 == " " }).first.map(String.init) ?? "10.182.122.0"
        model.cidr = "\(head.trimmingCharacters(in: .whitespaces))/\(prefix)"
    }

    private var quickRanges: some View {
        var list = state.ranges.compactMap { range -> String? in
            (try? Subnet(parsing: range.text))?.description
        }
        if let local = state.activeInterface?.subnet.description { list.insert(local, at: 0) }
        for extra in ["192.168.1.0/24", "172.16.0.0/12"] where list.count < 5 { list.append(extra) }
        var seen = Set<String>()
        let unique = list.filter { seen.insert($0).inserted }.prefix(6)
        let current = model.cidr.trimmingCharacters(in: .whitespaces)
        return ToolFlowLayout(spacing: 6) {
            Text("Plages récentes\u{00A0}:").font(Theme.small).foregroundStyle(Theme.textSecondary).frame(height: 28)
            ForEach(Array(unique), id: \.self) { text in
                ToolChoiceChip(label: text, isSelected: text == current) { model.cidr = text }
            }
        }
    }

    // MARK: Résultats

    @ViewBuilder
    private func results(_ calc: SubnetCalculation) -> some View {
        let subnet = calc.subnet
        inventoryNote(subnet)
        ToolCellGrid(cells: cells(calc), columns: 3)
        binaryBlock(calc)
        splitBlock(subnet)
    }

    private func inventoryNote(_ subnet: Subnet) -> some View {
        let known = state.devices.filter { subnet.contains($0.ip) }
        let online = known.filter(\.isOnline).count
        var parts: [String] = []
        if known.isEmpty {
            parts.append("Aucun appareil connu dans cette plage pour l’instant.")
        } else {
            parts.append(known.count == 1 ? "1 appareil connu dans cette plage" : "\(known.count) appareils connus dans cette plage")
            parts.append(online <= 1 ? "\(online) en ligne" : "\(online) en ligne")
        }
        if let iface = state.activeInterface, subnet.contains(iface.address) {
            if let gateway = iface.gateway { parts.append("passerelle \(gateway)") }
            parts.append("réseau de \(iface.name)")
        }
        if let range = state.ranges.first(where: { (try? Subnet(parsing: $0.text)) == subnet }) {
            parts.append("plage « \(range.label) »" + (range.vlan.map { " · VLAN \($0)" } ?? ""))
        }
        let alreadySaved = state.ranges.contains { (try? Subnet(parsing: $0.text)) == subnet }
        return ToolNotice(tone: .accent, message: parts.joined(separator: " · ")) {
            Button(alreadySaved ? "Ouvrir le Scanner →" : "Scanner cette plage →") {
                if !alreadySaved, subnet.totalAddresses <= IPRange.maxAddresses {
                    state.ranges.append(ScanRangeConfig(text: subnet.description, label: "Outils"))
                }
                store.record(command: "ipcalc \(subnet) → scanner")
                state.open(.scanner)
            }
            .buttonStyle(.ghost)
            .fixedSize()
        }
    }

    private func cells(_ calc: SubnetCalculation) -> [ToolCell] {
        let s = calc.subnet
        let p = s.prefix
        let entered = calc.entered != s.network ? "IP saisie \(calc.entered) ramenée au réseau" : "réseau exact"
        let firstName = state.devices.first { $0.ip == s.firstHost }.map { "\($0.displayName)" } ?? "souvent la passerelle"
        let hostsDetail: String
        switch p {
        case 31: hostsDetail = "RFC 3021 point à point"
        case 32: hostsDetail = "hôte unique"
        default: hostsDetail = "2^\(32 - p) − 2"
        }
        let scope = calc.scopeText
        return [
            ToolCell(key: "Adresse réseau", value: s.description, detail: entered),
            ToolCell(key: "Masque", value: s.mask.description, detail: "/\(p) · \(p) bits réseau"),
            ToolCell(key: "Masque inverse", value: s.wildcard.description, detail: "wildcard pour ACL Cisco / OSPF"),
            ToolCell(key: "Broadcast", value: p >= 31 ? "—" : s.broadcast.description,
                     detail: p >= 31 ? "aucun (lien point à point)" : "dernière adresse du bloc"),
            ToolCell(key: "Premier hôte", value: s.firstHost.description, detail: firstName),
            ToolCell(key: "Dernier hôte", value: s.lastHost.description,
                     detail: "plage de \(ToolFormat.integer(s.totalAddresses)) adresses au total"),
            ToolCell(key: "Hôtes utilisables", value: ToolFormat.integer(s.hostCount), detail: hostsDetail),
            ToolCell(key: "Classe", value: s.addressClass, detail: calc.classDetail),
            ToolCell(key: "Type d’adresse", value: scope.0, detail: scope.1),
        ]
    }

    private func binaryBlock(_ calc: SubnetCalculation) -> some View {
        let p = calc.subnet.prefix
        let rows: [(String, IPv4Address)] = [("Adresse", calc.entered), ("Masque", calc.subnet.mask), ("Masque inverse", calc.subnet.wildcard)]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ToolFieldLabel("Représentation binaire")
                Spacer()
                legend(color: Theme.accent, text: "Bits réseau (\(p))")
                legend(color: Color(hex: 0x9CA3AF), text: "Bits hôte (\(32 - p))")
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { row in
                    let parts = SubnetCalculation.binaryParts(row.1, prefix: p)
                    HStack(spacing: 12) {
                        Text(row.0).font(Theme.small).foregroundStyle(Theme.textSecondary).frame(width: 120, alignment: .leading)
                        (Text(parts.0).foregroundColor(Theme.accentStrong).fontWeight(.semibold)
                            + Text(parts.1).foregroundColor(Theme.textSecondary))
                            .font(Theme.mono(13))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Découpage

    private func splitBlock(_ subnet: Subnet) -> some View {
        let p = subnet.prefix
        let canSplit = p <= 30
        let sp = (p + 1...30).contains(model.splitPrefix) ? model.splitPrefix : min(p + 2, 30)
        let maxChip = min(30, p + 6)
        let pieces = canSplit ? ((try? subnet.split(into: sp)) ?? []) : []
        let hosts = canSplit ? Subnet(address: subnet.network, prefix: sp).hostCount : 0
        let summary = canSplit
            ? "\(ToolFormat.integer(pieces.count)) sous-réseaux /\(sp) · \(ToolFormat.integer(hosts)) hôtes utilisables chacun · masque \(IPv4Address.mask(prefix: sp))"
            : "Bloc trop petit pour être découpé."
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Découpage en sous-réseaux").font(Theme.bodySemibold)
                    Text(summary).font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                if canSplit {
                    ToolFlowLayout(spacing: 4) {
                        ForEach(Array((p + 1)...max(p + 1, maxChip)), id: \.self) { value in
                            ToolChoiceChip(label: "/\(value) (\(ToolFormat.integer(1 << (value - p))))", isSelected: value == sp) {
                                model.splitPrefix = value
                            }
                        }
                    }
                }
            }
            .padding(12)
            if canSplit {
                TableHeader(columns: [
                    .init(title: "#", width: 44), .init(title: "Sous-réseau", width: 170), .init(title: "Plage d’hôtes"),
                    .init(title: "Broadcast", width: 130), .init(title: "Hôtes", width: 80, alignment: .trailing),
                ])
                ForEach(Array(pieces.prefix(Self.maxRows).enumerated()), id: \.offset) { index, piece in
                    ToolTableRow {
                        Text("\(index + 1)").font(Theme.small).foregroundStyle(Theme.textSecondary).toolCell(44)
                        Text(piece.description).font(Theme.mono(12, weight: .semibold)).toolCell(170)
                        Text("\(piece.firstHost.description) – \(piece.lastHost.description)").font(Theme.mono(12)).toolCell(nil)
                        Text(piece.broadcast.description).font(Theme.mono(12)).toolCell(130)
                        Text(ToolFormat.integer(piece.hostCount)).font(Theme.mono(12)).toolCell(80, alignment: .trailing)
                    }
                }
                HStack {
                    if pieces.count > Self.maxRows {
                        Text("… et \(ToolFormat.integer(pieces.count - Self.maxRows)) autres sous-réseaux.")
                            .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Copier en CSV") {
                        let lines = ["sous_reseau;premier_hote;dernier_hote;broadcast;hotes"] + pieces.map {
                            "\($0);\($0.firstHost);\($0.lastHost);\($0.broadcast);\($0.hostCount)"
                        }
                        ToolActions.copy(lines.joined(separator: "\n"))
                        store.record(command: "ipcalc \(subnet) --split \(sp)")
                    }
                    .buttonStyle(.ghost)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            } else {
                Text("Un /31 ou /32 ne peut pas être découpé davantage.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}
