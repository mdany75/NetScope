import NetScopeCore
import SwiftUI

/// Réglages › Profils de scan › Méthodes de découverte (croquis : cases « ICMP (ping) », « ARP »,
/// « TCP SYN »…) : enregistrées pour chaque profil, lues par le Scanner au lancement du scan.
struct RegMethodsPanel: View {
    @ObservedObject private var prefs = RegPrefs.shared
    @State private var profile: ScanProfile = RegPrefs.shared.defaultProfile
    @State private var tcpText = ""
    @State private var udpText = ""

    private struct Method: Identifiable {
        let id: String
        let label: String
        let detail: String
        let keyPath: WritableKeyPath<ScanMethods, Bool>
    }

    private static let list: [Method] = [
        Method(id: "icmp", label: "ICMP (ping)", detail: "Echo request vers chaque adresse, toutes plages", keyPath: \.icmp),
        Method(id: "arp", label: "ARP", detail: "Table ARP après les pings ; même segment, le plus fiable", keyPath: \.arp),
        Method(id: "tcp", label: "TCP (connexion)", detail: "Adresses muettes au ping : connexion aux ports choisis", keyPath: \.tcp),
        Method(id: "udp", label: "UDP", detail: "Lent : réponse ou « port injoignable » (53, 123, 137…)", keyPath: \.udp),
        Method(id: "dns", label: "DNS inverse", detail: "Requête PTR pour chaque hôte trouvé", keyPath: \.reverseDNS),
        Method(id: "mdns", label: "mDNS / Bonjour", detail: "Noms .local des Mac, imprimantes, NAS", keyPath: \.mdns),
        Method(id: "netbios", label: "NetBIOS", detail: "Nom et groupe de travail Windows", keyPath: \.netbios),
        Method(id: "snmp", label: "SNMP", detail: "Switchs et routeurs : sysName, tables MAC (Identifiants)", keyPath: \.snmp),
        Method(id: "lldp", label: "LLDP / CDP passif", detail: "Écoute du switch voisin pendant le scan (accès /dev/bpf)", keyPath: \.lldp),
    ]

    private var methods: ScanMethods { prefs.methods(for: profile) }

    private func binding(_ keyPath: WritableKeyPath<ScanMethods, Bool>) -> Binding<Bool> {
        Binding(get: { prefs.methods(for: profile)[keyPath: keyPath] },
                set: { value in
                    var copy = prefs.methods(for: profile)
                    copy[keyPath: keyPath] = value
                    prefs.setMethods(copy, for: profile)
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                header
                Spacer(minLength: 8)
                resetButton
            }
            RegSegmented(selection: $profile, options: ScanProfile.allCases.map { .init(value: $0, label: $0.label) })
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                ForEach(Self.list) { method in
                    methodBox(method)
                }
            }
            if methods.tcp || methods.udp {
                HStack(alignment: .top, spacing: 12) {
                    if methods.tcp {
                        portsField(title: "Ports TCP de présence", text: $tcpText, placeholder: "22, 80, 443, 445, 3389") { ports in
                            var copy = methods
                            copy.tcpPorts = ports.isEmpty ? ScanMethods.defaultTCPPorts : ports
                            prefs.setMethods(copy, for: profile)
                        }
                    }
                    if methods.udp {
                        portsField(title: "Ports UDP de présence", text: $udpText, placeholder: "53, 123, 137, 161, 1900, 5353") { ports in
                            var copy = methods
                            copy.udpPorts = ports.isEmpty ? ScanMethods.defaultUDPPorts : ports
                            prefs.setMethods(copy, for: profile)
                        }
                    }
                }
            }
            notes
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
        .onAppear(perform: syncPorts)
        .onChange(of: profile) { _, _ in syncPorts() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MÉTHODES DE DÉCOUVERTE").font(Theme.captionSemibold).kerning(0.55).foregroundStyle(Theme.textSecondary)
            Text("Enregistrées pour chaque profil ; le Scanner les applique au prochain scan.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
        }
    }

    private var resetButton: some View {
        Button("Méthodes par défaut") {
            prefs.setMethods(ScanMethods.defaults(for: profile), for: profile)
            syncPorts()
        }
        .buttonStyle(RegSmallButtonStyle())
        .regDisabled(methods == ScanMethods.defaults(for: profile))
        .help("Rétablir les méthodes d’origine de ce profil (comportement des versions précédentes)")
        .fixedSize()
    }

    private func methodBox(_ method: Method) -> some View {
        let isOn = methods[keyPath: method.keyPath]
        return Toggle(isOn: binding(method.keyPath)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(method.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text(method.detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(isOn ? Theme.accentSoft : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(isOn ? Theme.accent.opacity(0.45) : Theme.border))
    }

    private func portsField(title: String, text: Binding<String>, placeholder: String, onCommit: @escaping ([UInt16]) -> Void) -> some View {
        let valid = ScanProfile.parsePorts(text.wrappedValue) != nil
        return RegField(label: title) {
            RegTextField(placeholder: placeholder, text: Binding(get: { text.wrappedValue }, set: { value in
                text.wrappedValue = value
                if let ports = ScanProfile.parsePorts(value), ports.count <= 64 { onCommit(ports) }
            }), mono: true, invalid: !valid)
        }
        .frame(maxWidth: 360)
    }

    private func syncPorts() {
        tcpText = methods.tcpPorts.map(String.init).joined(separator: ", ")
        udpText = methods.udpPorts.map(String.init).joined(separator: ", ")
    }

    @ViewBuilder private var notes: some View {
        let plan = ScanPlan(options: { var options = ScanOptions(profile: profile); options.methods = methods; return options }(),
                            autoDiscoverSwitches: prefs.autoDiscoverSwitches)
        if plan.findsNothing {
            RegNotice("Aucune méthode de présence cochée (ICMP, ARP, TCP ou UDP) : ce profil ne trouvera aucun appareil.", tone: .critical)
        } else if !methods.icmp {
            RegNotice("Sans ICMP, la table ARP ne contient que les appareils déjà contactés par ce Mac : cochez TCP ou UDP pour les autres.", tone: .warning)
        } else if methods.snmp, !plan.snmp {
            RegNotice("SNMP est coché, mais la découverte automatique des switchs est coupée (Réglages › Switchs) : seul le profil Complet la fait.", tone: .neutral)
        } else if methods.lldp {
            RegNotice("LLDP/CDP passif demande l’accès à /dev/bpf (ChmodBPF de Wireshark) ; sinon, l’outil «\u{00A0}\(ToolKind.lldp.label)\u{00A0}» de la Boîte à outils le demande à macOS.", tone: .neutral)
        } else {
            Text("TCP SYN demi-ouvert et SSDP demandent des droits d’administrateur : NetScope utilise la connexion TCP complète et mDNS.")
                .font(Theme.small).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
