import AppKit
import NetScopeCore
import SwiftUI
import UniformTypeIdentifiers

/// Réglages › Sites et plages (note 28) : la liste des sites (tableau standard), puis le site
/// choisi : ses plages (ajout, nom, VLAN, inclusion au scan), ses FortiGate, ses switchs SNMP, ses
/// indices de détection et ses notes. Chaque site a son propre inventaire ; le supprimer le
/// supprime aussi (après confirmation). Plusieurs sites peuvent avoir les mêmes plages : le site se
/// choisit par la passerelle, jamais par l'adresse IP seule.
struct RegSitesSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    @StateObject private var siteTable = RegSiteTable.makeModel()
    @StateObject private var table = RegRangeTable.makeModel()
    @State private var selectedID: UUID?
    @State private var newText = ""
    @State private var newLabel = ""
    @State private var newVLAN = ""
    @State private var error: String?
    @State private var message: (text: String, tone: Tone)?
    @State private var csvErrors: [String] = []
    @State private var naming: RegSiteNaming?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sitesPanel
            if let site = selectedSite {
                sitePanel(site)
            }
        }
        .onAppear { if selectedID == nil || selectedSite == nil { selectedID = sites.activeID ?? sites.sortedSites.first?.id } }
        .onChange(of: sites.activeID) { _, id in if id != nil { selectedID = id } }
        .onChange(of: selectedID) { _, _ in
            error = nil
            newText = ""
            newLabel = ""
            newVLAN = ""
        }
        .sheet(item: $naming) { naming in
            RegSiteNameSheet(naming: naming) { name in apply(naming, name: name) }
        }
    }

    private var selectedSite: Site? { selectedID.flatMap { sites.site($0) } }

    // MARK: Liste des sites

    private var sitesPanel: some View {
        RegPanel(title: "Sites et plages",
                 subtitle: "Un site par client ou par lieu (au besoin nommé d’après le client)\u{00A0}: ses plages, ses FortiGate, ses switchs SNMP et son propre inventaire. Plusieurs sites peuvent avoir les mêmes plages\u{00A0}: le site se reconnaît par sa passerelle, jamais par l’adresse IP seule.",
                 accessory: {
                     HStack(spacing: 8) {
                         Button { naming = .new } label: { Label("Nouveau site", systemImage: "plus") }
                             .buttonStyle(.secondary)
                             .fixedSize()
                         Menu {
                             Button("Créer depuis les FortiGate") { show(sites.createFromFortiGates(), .success) }
                                 .disabled(fortigate.controllers.isEmpty)
                             Divider()
                             Button("Importer CSV…", action: importCSV)
                             Button("Exporter CSV…", action: exportCSV)
                                 .disabled(sites.sites.isEmpty)
                         } label: {
                             Label("Plus", systemImage: "ellipsis.circle")
                         }
                         .menuStyle(.button)
                         .fixedSize()
                         .help("Créer les sites depuis les FortiGate, importer ou exporter le CSV «\u{00A0}site;plages;fortigate\u{00A0}», avec la colonne «\u{00A0}exclusions\u{00A0}» si un site a des plages exclues (aucun secret)")
                     }
                 }, content: {
                     if let message {
                         RegNotice(text: message.text, tone: message.tone) {
                             Button { self.message = nil; csvErrors = [] } label: { Image(systemName: "xmark") }
                                 .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                         }
                         .padding(.bottom, 8)
                         ForEach(csvErrors.prefix(5), id: \.self) { line in
                             Text(line).font(Theme.small).foregroundStyle(Theme.critical)
                         }
                     }
                     HStack(alignment: .center, spacing: 5) {
                         Text("\(sites.sites.count) SITE\(sites.sites.count > 1 ? "S" : "")")
                             .font(Theme.captionSemibold).kerning(0.55).foregroundStyle(Theme.textSecondary)
                         Text("· actif\u{00A0}: \(sites.activeName)").font(Theme.small).foregroundStyle(Theme.textSecondary)
                         Spacer(minLength: 8)
                         StandardColumnsMenu(model: siteTable)
                     }
                     .padding(.bottom, 6)
                     if sites.sites.isEmpty {
                         Text("Aucun site. «\u{00A0}Nouveau site\u{00A0}», «\u{00A0}Créer depuis les FortiGate\u{00A0}» ou, dans le Scanner, «\u{00A0}Enregistrer les plages comme site…\u{00A0}».")
                             .font(Theme.small).foregroundStyle(Theme.textSecondary)
                             .padding(18).frame(maxWidth: .infinity)
                             .regTableFrame()
                     } else {
                         RegSiteTable(table: siteTable, selection: $selectedID, onDelete: confirmDelete,
                                      onRename: { naming = .rename($0.id, $0.displayName) })
                             .regTableFrame()
                     }
                 })
    }

    // MARK: Site choisi

    private func sitePanel(_ site: Site) -> some View {
        let isActive = site.id == sites.activeID
        return RegPanel(title: site.displayName,
                        subtitle: isActive ? "Site actif\u{00A0}: le Scanner utilise ces plages, et l’inventaire affiché est le sien."
                                           : "Ses plages, son inventaire et ses résultats sont rechargés quand on l’active.",
                        accessory: {
                            HStack(spacing: 8) {
                                if !isActive {
                                    Button { sites.activate(site.id, state: state) } label: { Label("Activer ce site", systemImage: "mappin.circle") }
                                        .buttonStyle(.primary)
                                }
                                Menu {
                                    Button("Renommer…") { naming = .rename(site.id, site.displayName) }
                                    Button("Dupliquer (sans l’inventaire)") { selectedID = sites.duplicate(site.id)?.id }
                                    Divider()
                                    Button("Supprimer le site et son inventaire…", role: .destructive) { confirmDelete(site) }
                                } label: {
                                    Label("Site", systemImage: "ellipsis.circle")
                                }
                                .menuStyle(.button)
                                .fixedSize()
                            }
                        }, content: {
                            if isActive, sites.hasUnsavedRanges(state) {
                                RegNotice(text: "Les plages du Scanner ont changé et ne sont pas enregistrées dans ce site.", tone: .warning) {
                                    Button("Mettre à jour le site") { sites.updateActiveSite(state) }
                                        .buttonStyle(.secondary)
                                }
                                .padding(.bottom, 10)
                            }
                            let twins = sites.list.sharingAddresses(with: site.id)
                            if !twins.isEmpty {
                                RegNotice("Plages en commun avec «\u{00A0}\(twins.map(\.displayName).joined(separator: "\u{00A0}», «\u{00A0}"))\u{00A0}»\u{00A0}: chaque site garde son inventaire, et «\u{00A0}Détecter mon site\u{00A0}» les distingue par la passerelle (MAC, numéro de série ou nom de la FortiGate).",
                                          tone: .neutral)
                                    .padding(.bottom, 10)
                            }
                            tiles(site)
                            HStack(alignment: .center) {
                                Text("PLAGES DU SITE")
                                    .font(Theme.captionSemibold).kerning(0.55).foregroundStyle(Theme.textSecondary)
                                Spacer(minLength: 8)
                                StandardColumnsMenu(model: table)
                            }
                            .padding(.top, 12).padding(.bottom, 6)
                            rangeTable(site)
                            addForm(site).padding(.top, 10)
                            RegColumns(minColumnWidth: 300) {
                                RegSiteFortiGateBox(site: site)
                                RegSiteHintsBox(site: site)
                            }
                            .padding(.top, 16)
                            // Note 77 : contrôleur UniFi, Omada ou Meraki du site (lecture seule).
                            RegSiteControllersBox(site: site)
                                .padding(.top, 12)
                            RegColumns(minColumnWidth: 300) {
                                RegSiteSwitchesBox(site: site)
                                RegSiteNotesBox(site: site)
                            }
                            .padding(.top, 12)
                            // Note 10 : ajout automatique et liste d'exclusion de l'inventaire du site.
                            RegSiteInventoryBox(site: site)
                                .padding(.top, 12)
                            // Note 82 : plages exclues du site, jamais sondées.
                            RegSiteExclusionsBox(site: site)
                                .padding(.top, 12)
                        })
        .id(site.id)
    }

    private func tiles(_ site: Site) -> some View {
        let active = site.ranges.filter(\.isEnabled)
        // Note 82 : sans les adresses des plages exclues.
        let parsed = active.compactMap { try? $0.parsed() }
        let exclusions = site.excludedAddresses
        let excluded = exclusions.excludedCount(in: parsed)
        let total = excluded == 0 ? parsed.reduce(0) { $0 + $1.count } : exclusions.probeCount(in: parsed)
        let gateways = site.hints.gatewayMACs.map { $0.formatted(.upperColon) }
        let count = sites.inventoryCount(site)
        return RegTileRow {
            // Insécables : la valeur passe à la ligne après « · », jamais au milieu de « 3 plages actives ».
            RegTile("Total à scanner", "\(RegFormat.count(total))\u{00A0}adresses\u{00A0}· \(active.count)\u{00A0}plage\(active.count > 1 ? "s" : "")\u{00A0}active\(active.count > 1 ? "s" : "")"
                    + (excluded > 0 ? "\u{00A0}· \(RegFormat.count(excluded))\u{00A0}exclue\(excluded > 1 ? "s" : "")" : ""))
            if site.fortiGateIDs.isEmpty, !site.controllers.isEmpty {
                // Note 77 : sans FortiGate, le contrôleur UniFi, Omada ou Meraki du site.
                RegTile("Contrôleur", site.controllers.map(\.kind.label).joined(separator: ", "))
            } else {
                RegTile("FortiGate", site.fortiGateIDs.compactMap { fortigate.controller($0)?.displayName }.joined(separator: ", ").nonEmpty ?? "Aucune (SNMP seulement)")
            }
            RegTile("Passerelle connue", gateways.first.map { gateways.count > 1 ? "\($0) +\(gateways.count - 1)" : $0 } ?? "Pas encore relevée", mono: true)
            RegTile("Inventaire", "\(RegFormat.count(count)) fiche\(count > 1 ? "s" : "")" + (site.lastScan.map { " · scan \(ScanFormat.relative($0).lowercased())" } ?? " · jamais scanné"))
        }
    }

    private func rangeTable(_ site: Site) -> some View {
        VStack(spacing: 0) {
            if !site.ranges.isEmpty {
                RegRangeTable(table: table, ranges: rangesBinding(site.id), siteName: site.displayName,
                              devices: site.id == sites.activeID ? state.devices : [])
            } else {
                Text("Aucune plage. Ajoutez-en une ci-dessous ou utilisez «\u{00A0}Mon réseau\u{00A0}» pour reprendre celui de l’interface active.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(18)
                    .frame(maxWidth: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private func rangesBinding(_ id: UUID) -> Binding<[ScanRangeConfig]> {
        Binding(get: { sites.site(id)?.ranges ?? [] }, set: { value in
            guard var site = sites.site(id) else { return }
            site.ranges = value
            sites.update(site, state: state)
        })
    }

    // MARK: Ajout d'une plage

    private var preview: String {
        let text = newText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return "Formats acceptés\u{00A0}: 10.0.0.0/24, 10.0.0.1-10.0.0.50, 10.0.0.1-50, liste 10.0.0.9, 10.0.0.12 — au plus \(RegFormat.count(Int(IPRange.maxAddresses))) adresses."
        }
        do {
            let range = try IPRange(parsing: text)
            let kind = ScanRangeConfig(text: text, label: "").kindLabel
            return "\(kind) · \(RegFormat.count(range.count)) adresse(s) à sonder"
        } catch {
            return error.localizedDescription
        }
    }

    private func addForm(_ site: Site) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Une seule ligne en grande fenêtre ; en petite, la plage, puis nom et VLAN, puis les boutons.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 8) {
                    rangeField(site).frame(minWidth: 240, idealWidth: 260, maxWidth: .infinity)
                    nameField.frame(width: 200)
                    vlanField.frame(width: 90)
                    addButtons(site)
                }
                VStack(alignment: .leading, spacing: 8) {
                    rangeField(site)
                    HStack(alignment: .bottom, spacing: 8) {
                        nameField.frame(maxWidth: .infinity)
                        vlanField.frame(width: 90)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        addButtons(site)
                    }
                }
            }
            Text(preview).font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private func rangeField(_ site: Site) -> some View {
        RegField(label: "Plage (CIDR, début-fin ou IP)") {
            RegTextField(placeholder: "172.16.0.0/22 ou 10.10.0.1-10.10.0.50", text: $newText, mono: true)
                .onSubmit { add(to: site.id) }
        }
        .lineLimit(1)
    }

    private var nameField: some View {
        RegField(label: "Nom") {
            RegTextField(placeholder: "Ex. Production", text: $newLabel)
        }
        .lineLimit(1)
    }

    private var vlanField: some View {
        RegField(label: "VLAN") {
            RegTextField(placeholder: "1–4094", text: $newVLAN, mono: true)
        }
        .lineLimit(1)
    }

    private func addButtons(_ site: Site) -> some View {
        HStack(spacing: 8) {
            Button { add(to: site.id) } label: { Label("Ajouter la plage", systemImage: "plus") }
                .buttonStyle(.secondary)
            Button { addDetected(to: site.id) } label: { Label("Mon réseau", systemImage: "scope") }
                .buttonStyle(.secondary)
                .regDisabled(state.activeInterface == nil)
                .help("Ajoute le réseau de l’interface active")
        }
        .fixedSize()
    }

    private func add(to id: UUID) {
        guard var site = sites.site(id) else { return }
        let text = newText.trimmingCharacters(in: .whitespaces)
        do {
            _ = try IPRange(parsing: text)
        } catch {
            self.error = "Plage invalide\u{00A0}: «\u{00A0}\(text.isEmpty ? "vide" : text)\u{00A0}». \(error.localizedDescription)"
            return
        }
        let vlanText = newVLAN.trimmingCharacters(in: .whitespaces)
        var vlan: Int?
        if !vlanText.isEmpty {
            guard let value = Int(vlanText), (1...4094).contains(value) else {
                error = "VLAN invalide\u{00A0}: saisir un nombre de 1 à 4094."
                return
            }
            vlan = value
        }
        if site.ranges.contains(where: { $0.text.replacingOccurrences(of: " ", with: "") == text.replacingOccurrences(of: " ", with: "") }) {
            error = "Cette plage est déjà enregistrée pour «\u{00A0}\(site.displayName)\u{00A0}»."
            return
        }
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        site.ranges.append(ScanRangeConfig(text: text, label: label.isEmpty ? "Nouvelle plage" : label, vlan: vlan))
        sites.update(site, state: state)
        newText = ""
        newLabel = ""
        newVLAN = ""
        error = nil
    }

    private func addDetected(to id: UUID) {
        guard let interface = state.activeInterface else { return }
        let subnet = interface.subnet.prefix < 16 ? Subnet(address: interface.address, prefix: 24) : interface.subnet
        newText = subnet.description
        if newLabel.isEmpty { newLabel = interface.kind == .wifi ? "Wi-Fi" : "Réseau local" }
        add(to: id)
    }

    // MARK: Actions

    private func apply(_ naming: RegSiteNaming, name: String) {
        switch naming {
        case .new:
            let site = Site(name: name)
            sites.add(site)
            selectedID = sites.sites.last?.id
            show("Site «\u{00A0}\(sites.sites.last?.displayName ?? name)\u{00A0}» créé\u{00A0}: ajoutez ses plages ci-dessous.", .success)
        case .rename(let id, _):
            sites.rename(id, to: name)
        }
    }

    private func confirmDelete(_ site: Site) {
        let count = sites.inventoryCount(site)
        let alert = NSAlert()
        alert.messageText = "Supprimer le site «\u{00A0}\(site.displayName)\u{00A0}»\u{00A0}?"
        alert.informativeText = "L’inventaire du site sera supprimé\u{00A0}: \(count) fiche\(count > 1 ? "s" : ""), leur historique, leurs événements (Historique et adressage), l’archive, les notes et les types choisis à la main, ainsi que ses derniers résultats de scan et son utilisateur SNMP v3. Les FortiGate et les switchs restent dans les Réglages. Une sauvegarde (Réglages › Export et sauvegarde) permet de le retrouver."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Supprimer le site et son inventaire")
        alert.addButton(withTitle: "Annuler")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = site.displayName
        sites.remove(site.id, state: state)
        selectedID = sites.activeID ?? sites.sortedSites.first?.id
        show("Site «\u{00A0}\(name)\u{00A0}» et son inventaire supprimés.", .neutral)
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.title = "Importer des sites"
        panel.prompt = "Importer"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            show("Lecture impossible de \(url.lastPathComponent).", .critical)
            return
        }
        let result = sites.importCSV(text, state: state)
        csvErrors = result.errors
        show(result.summary, result.errors.isEmpty ? .success : .warning)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Exporter les sites"
        panel.prompt = "Exporter"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "NetScope-sites.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sites.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            show("\(sites.sites.count) site\(sites.sites.count > 1 ? "s" : "") exporté\(sites.sites.count > 1 ? "s" : "") dans \(url.lastPathComponent) (aucun secret).", .success)
        } catch {
            show("Export impossible\u{00A0}: \(error.localizedDescription)", .critical)
        }
    }

    private func show(_ text: String, _ tone: Tone) {
        message = (text, tone)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Nom d'un site (nouveau, renommer)

enum RegSiteNaming: Identifiable {
    case new
    case rename(UUID, String)

    var id: String {
        switch self {
        case .new: return "nouveau"
        case .rename(let id, _): return id.uuidString
        }
    }
}

struct RegSiteNameSheet: View {
    let naming: RegSiteNaming
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Nouveau site" : "Renommer le site").font(Theme.panelTitle)
            RegField(label: "Nom (au besoin, celui du client)") {
                RegTextField(placeholder: "Ex. Clinique Exemple ou Groupe X · Laval", text: $name)
                    .onSubmit(save)
            }
            Text(isNew ? "Le site part sans plage et avec un inventaire vide." : "Le nom suit le site dans le Scanner, la barre latérale et les rapports.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button(isNew ? "Créer le site" : "Renommer", action: save)
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { if case .rename(_, let current) = naming { name = current } }
    }

    private var isNew: Bool { if case .new = naming { return true } else { return false } }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        dismiss()
        onSave(trimmed)
    }
}
