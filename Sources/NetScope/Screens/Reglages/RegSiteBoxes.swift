import NetScopeCore
import SwiftUI

// Encadrés du site choisi dans Réglages › Sites et plages (note 28) : FortiGate associées,
// indices de détection, switchs SNMP associés, notes.

/// Encadré commun : titre 11 pt majuscules, contenu, bordure fine.
struct RegSiteBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(Theme.captionSemibold).kerning(0.55).foregroundStyle(Theme.textSecondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// FortiGate du site : celles qu'on lit quand il est actif (la plage IP ne sert plus au choix).
struct RegSiteFortiGateBox: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    let site: Site

    var body: some View {
        RegSiteBox(title: "FortiGate du site") {
            if fortigate.controllers.isEmpty {
                Text("Aucune FortiGate dans Réglages › Switchs › Contrôleurs FortiGate. Sans FortiGate, les switchs sont lus en SNMP.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(fortigate.controllers) { controller in
                    Toggle(isOn: binding(controller.id)) {
                        HStack(spacing: 6) {
                            Text(controller.displayName).font(Theme.small)
                            Text(controller.addressLabel).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                            let others = sites.sites.filter { $0.id != site.id && $0.fortiGateIDs.contains(controller.id) }
                            if !others.isEmpty {
                                Text("site\u{00A0}: \(others.map(\.displayName).joined(separator: ", "))")
                                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Text(site.fortiGateIDs.isEmpty
                     ? "Aucune FortiGate cochée\u{00A0}: quand ce site est actif, aucune n’est lue (jamais celle d’un autre client aux mêmes plages)."
                     : "Quand ce site est actif, seules les FortiGate cochées sont lues (FortiSwitch, Wi-Fi FortiAP).")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { sites.site(site.id)?.fortiGateIDs.contains(id) ?? false }, set: { on in
            guard var current = sites.site(site.id) else { return }
            if on, !current.fortiGateIDs.contains(id) { current.fortiGateIDs.append(id) }
            if !on { current.fortiGateIDs.removeAll { $0 == id } }
            SiteFortiGate.refreshHints(&current, controllers: fortigate.controllers)
            sites.update(current, state: state)
        })
    }
}

/// Indices de détection : MAC de la passerelle, numéro de série et nom d'hôte de la FortiGate, SSID.
struct RegSiteHintsBox: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    let site: Site
    @State private var macs = ""
    @State private var serials = ""
    @State private var hostnames = ""
    @State private var ssid = ""
    @State private var problem: String?
    @State private var saved = false

    var body: some View {
        RegSiteBox(title: "Indices de détection") {
            Text("«\u{00A0}Détecter mon site\u{00A0}» reconnaît le site par ces indices, jamais par l’adresse IP seule. La MAC de la passerelle est retenue au premier scan du site.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            field("MAC de la passerelle", text: $macs, placeholder: "04:D5:90:3A:7B:11", mono: true)
            field("Numéro de série de la FortiGate", text: $serials, placeholder: "FGT60FTK22004711", mono: true)
            field("Nom d’hôte de la FortiGate", text: $hostnames, placeholder: "FGT-SIEGE", mono: true)
            field("SSID (facultatif, indice faible)", text: $ssid, placeholder: "Bureau-Corp", mono: false)
            VStack(alignment: .leading, spacing: 8) {
                if let problem {
                    Text(problem).font(Theme.small).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
                } else if saved {
                    Text("Indices enregistrés.").font(Theme.small).foregroundStyle(Theme.success)
                } else if isDirty {
                    Text("Modifications non enregistrées").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warning)
                }
                ActionRow {
                    Button("Enregistrer les indices", action: save)
                        .buttonStyle(.secondary)
                        .regDisabled(!isDirty)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: site.hints) { _, _ in load() }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            RegTextField(placeholder: placeholder, text: text, mono: mono)
                .onChange(of: text.wrappedValue) { _, _ in saved = false; problem = nil }
        }
    }

    private static func list(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var draft: SiteHints? {
        var hints = SiteHints()
        for token in Self.list(macs) {
            guard let mac = MACAddress(token) else { return nil }
            hints.learn(gatewayMAC: mac)
        }
        for serial in Self.list(serials) { hints.learn(serial: serial, hostname: nil) }
        for host in Self.list(hostnames) { hints.learn(serial: nil, hostname: host) }
        let trimmed = ssid.trimmingCharacters(in: .whitespaces)
        hints.ssid = trimmed.isEmpty ? nil : trimmed
        return hints
    }

    private var isDirty: Bool { draft.map { $0 != (sites.site(site.id)?.hints ?? SiteHints()) } ?? true }

    private func load() {
        let hints = sites.site(site.id)?.hints ?? site.hints
        macs = hints.gatewayMACs.map { $0.formatted(.upperColon) }.joined(separator: ", ")
        serials = hints.fortiGateSerials.joined(separator: ", ")
        hostnames = hints.fortiGateHostnames.joined(separator: ", ")
        ssid = hints.ssid ?? ""
    }

    private func save() {
        guard let hints = draft else {
            problem = "MAC illisible\u{00A0}: saisir des adresses comme 04:D5:90:3A:7B:11, séparées par des virgules."
            return
        }
        guard var current = sites.site(site.id) else { return }
        current.hints = hints
        sites.update(current, state: state)
        saved = true
    }
}

/// Switchs SNMP (non Fortinet) associés au site : choisis dans Réglages › Switchs.
struct RegSiteSwitchesBox: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var store = SwitchStore.shared
    let site: Site

    var body: some View {
        RegSiteBox(title: "Switchs SNMP associés") {
            let hosts = sites.site(site.id)?.switchHosts ?? []
            if hosts.isEmpty {
                Text("Aucun. Un switch sans site n’apparaît dans «\u{00A0}Switchs et ports\u{00A0}» que s’il est dans les plages scannées.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(hosts, id: \.self) { host in
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.connected.to.line.below").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Text(host).font(Theme.mono(12, weight: .semibold))
                    Text(store.snapshots[host]?.displayName ?? "").font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        var ids = Set(sites.sites(forSwitch: host).map(\.id))
                        ids.remove(site.id)
                        sites.setSwitch(host, sites: ids)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                        .help("Retirer \(host) de ce site")
                }
            }
            ActionRow {
                Button("Choisir dans Réglages › Switchs") { RegNavigation.shared.section = .switchs }
                    .buttonStyle(.secondary)
            }
        }
    }
}

/// Notes libres du site (client, contact, accès).
struct RegSiteNotesBox: View {
    @ObservedObject private var sites = SiteModel.shared
    let site: Site
    @State private var notes = ""

    var body: some View {
        RegSiteBox(title: "Notes") {
            TextEditor(text: $notes)
                .font(Theme.small)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 70)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            Text("Aucun secret ici\u{00A0}: les mots de passe vont au Trousseau (Réglages › Identifiants).")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
        .onAppear { notes = site.notes }
        .onChange(of: notes) { _, value in
            // Notes seulement : ni les plages du Scanner ni les FortiGate ne sont touchées.
            sites.setNotes(value, for: site.id)
        }
    }
}
