import NetScopeCore
import SwiftUI

/// Panneau de droite de l'écran Journaux : récepteurs Syslog (UDP et TCP) et traps de ce Mac
/// (ports, état, arrêt automatique, coupe-feu), guide de configuration par marque, transfert vers un
/// autre serveur Syslog (note 78), lecture des journaux de la FortiGate et conservation du journal.
struct LogReceiversPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = LogStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    let keys: [String]
    let since: Date
    let until: Date?
    @State private var syslogText = ""
    @State private var trapText = ""
    @State private var forwardPortText = ""
    @State private var example = 0
    @State private var exampleKind = 0
    @State private var brand: LogDeviceGuide.Brand = .fortigate
    @State private var guideTransport: SyslogTransport = .udp
    /// Une communauté SNMP est enregistrée (Trousseau) ; lue à l'apparition, pas à chaque rendu.
    @State private var hasCommunity = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            receivers
            guide
            forwardPanel
            fortiGatePanel
            retentionPanel
        }
        .onAppear {
            syslogText = String(store.syslogPort)
            trapText = String(store.trapPort)
            forwardPortText = String(store.forward.port)
            hasCommunity = store.isDemo || !(RegSNMPCredentials.load()?.community ?? "").isEmpty
            if store.isDemo {
                brand = JournauxDemo.guideBrand ?? brand
                guideTransport = JournauxDemo.guideTransport ?? guideTransport
            }
        }
    }

    // MARK: Récepteurs

    private var receivers: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MonHeading("Récepteurs de ce Mac")
                Spacer(minLength: 6)
                if store.isListening, let stopAt = store.stopAt {
                    Text("arrêt à \(LogFormat.time(stopAt).prefix(5))")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
            }
            receiverRow(title: "Syslog", detail: "RFC\u{00A0}3164, RFC\u{00A0}5424, FortiOS", enabled: $store.syslogEnabled,
                        transport: store.syslogTCPEnabled ? "UDP/TCP" : "UDP",
                        text: $syslogText, listening: store.isSyslogListening, error: syslogErrors,
                        countText: syslogCountText, standard: 514) { store.syslogPort = $0 }
            ToolCheckbox(label: "Recevoir aussi en TCP (RFC\u{00A0}6587, même port)", isOn: $store.syslogTCPEnabled)
                .disabled(store.isListening || !store.syslogEnabled)
                .padding(.leading, 20)
                .help("Cadrage par longueur (mode «\u{00A0}reliable\u{00A0}» de FortiOS, rsyslog) et par saut de ligne (Cisco, AOS-S)\u{00A0}: aucun message perdu, même en rafale.")
            receiverRow(title: "Traps SNMP", detail: "v1 et v2c, informs acquittés", enabled: $store.trapsEnabled, transport: "UDP",
                        text: $trapText, listening: store.trapListening, error: store.trapError,
                        countText: LogFormat.count(store.receivedCount[.trap] ?? 0, "message reçu", "messages reçus"), standard: 162) { store.trapPort = $0 }
            ToolCheckbox(label: "N’accepter que les traps de la communauté SNMP enregistrée", isOn: $store.checkCommunity)
                .disabled(store.isListening || !hasCommunity)
                .help(hasCommunity
                      ? "Communauté de Réglages › Identifiants · conservée au Trousseau, jamais écrite dans le journal."
                      : "Aucune communauté SNMP enregistrée\u{00A0}: ajoutez-la dans Réglages › Identifiants (conservée au Trousseau).")
            HStack(spacing: 6) {
                Text("Arrêt automatique").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                Picker("Arrêt automatique", selection: $store.autoStopMinutes) {
                    ForEach(LogStore.autoStopChoices, id: \.self) { minutes in
                        Text(Self.autoStopLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .onChange(of: store.autoStopMinutes) { _, _ in store.autoStopChanged() }
            }
            Button {
                store.isListening ? store.stop() : store.start()
            } label: {
                Label(store.isListening ? "Arrêter la réception" : "Démarrer la réception",
                      systemImage: store.isListening ? "stop.fill" : "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(store.isListening ? AnyPrimitiveButtonStyle(.secondary) : AnyPrimitiveButtonStyle(.primary))
            .disabled(!store.syslogEnabled && !store.trapsEnabled)
            if let reason = store.lastStopReason, !store.isListening {
                Text(reason).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.rejectedCount > 0, let rejection = store.lastRejection {
                Text("\(store.rejectedCount) écarté\(store.rejectedCount > 1 ? "s" : "")\u{00A0}: \(rejection)")
                    .font(Theme.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = store.firewall?.logWarning {
                ToolNotice(tone: .warning, message: warning)
            }
            Text("Ports au-dessus de 1024 par défaut\u{00A0}: aucun droit administrateur n’est nécessaire. Les ports standard (514 et 162) demandent les droits root sur certains Mac\u{00A0}: réglez plutôt le port de NetScope sur l’équipement (guide ci-dessous). Certains équipements n’envoient leurs traps que vers le port 162.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    private var syslogErrors: String? {
        let list = [store.syslogError, store.syslogTCPError].compactMap { $0 }
        return list.isEmpty ? nil : list.joined(separator: "\n")
    }

    /// « 12 messages reçus, dont 5 en TCP · 2 connexions TCP ».
    private var syslogCountText: String {
        var text = LogFormat.count(store.receivedCount[.syslog] ?? 0, "message reçu", "messages reçus")
        if store.receivedTCP > 0 { text += ", dont \(store.receivedTCP) en TCP" }
        if store.syslogTCPListening, store.tcpConnections > 0 {
            text += " · " + LogFormat.count(store.tcpConnections, "connexion TCP", "connexions TCP")
        }
        return text
    }

    static func autoStopLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Jamais"
        case let m where m >= 60: return "Après \(m / 60)\u{00A0}h"
        default: return "Après \(minutes)\u{00A0}min"
        }
    }

    private func receiverRow(title: String, detail: String, enabled: Binding<Bool>, transport: String, text: Binding<String>, listening: Bool,
                             error: String?, countText: String, standard: UInt16, apply: @escaping (UInt16) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle(isOn: enabled) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                        Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(store.isListening)
                Spacer(minLength: 6)
                Text(transport).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize()
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .frame(width: 62)
                    .disabled(store.isListening)
                    .onSubmit { commit(text, apply: apply) }
                    .onChange(of: text.wrappedValue) { _, _ in commit(text, apply: apply) }
                    .help("Port d’écoute (standard\u{00A0}: \(standard))")
            }
            HStack(spacing: 6) {
                if listening {
                    Chip(text: "En écoute", tone: .success, systemImage: "dot.radiowaves.left.and.right")
                    Text(countText)
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if enabled.wrappedValue {
                    Chip(text: "Arrêté", tone: .neutral)
                } else {
                    Chip(text: "Désactivé", tone: .neutral)
                }
            }
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commit(_ text: Binding<String>, apply: (UInt16) -> Void) {
        if let port = UInt16(text.wrappedValue.trimmingCharacters(in: .whitespaces)), port > 0 { apply(port) }
    }

    // MARK: Guide de configuration (note 78)

    private var macAddress: String { state.activeInterface?.address.description ?? "<adresse du Mac>" }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonHeading("Guide de configuration")
            HStack(spacing: 8) {
                Picker("Type", selection: $exampleKind) {
                    Text("Syslog").tag(0)
                    Text("Traps").tag(1)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: exampleKind) { _, _ in example = 0 }
                if exampleKind == 0 {
                    Picker("Transport", selection: Binding(get: { brand.supportsTCP ? guideTransport : .udp }, set: { guideTransport = $0 })) {
                        ForEach(SyslogTransport.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(!brand.supportsTCP)
                    .help(brand.supportsTCP ? "UDP\u{00A0}: le plus répandu. TCP\u{00A0}: aucun message perdu (activez «\u{00A0}Recevoir aussi en TCP\u{00A0}»)." : "Cet équipement n’envoie qu’en UDP.")
                }
                Spacer(minLength: 0)
            }
            if exampleKind == 0 { syslogGuide } else { trapGuide }
            Text("Adresse de ce Mac\u{00A0}: \(macAddress). Les messages sont rattachés au site actif («\u{00A0}\(SiteModel.shared.activeName)\u{00A0}») au moment de leur réception.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    private var brandPicker: some View {
        Picker("Équipement", selection: $brand) {
            ForEach(Self.families, id: \.self) { family in
                Section(family) {
                    ForEach(LogDeviceGuide.Brand.allCases.filter { $0.family == family }) { item in
                        Text(item.label).tag(item)
                    }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
    }

    static let families = ["Fortinet", "Cisco", "HP/Aruba", "Ubiquiti", "Autres"]

    @ViewBuilder private var syslogGuide: some View {
        let step = LogDeviceGuide.syslog(brand, mac: macAddress, port: store.syslogPort, transport: guideTransport)
        brandPicker
        if guideTransport == .tcp, !brand.supportsTCP {
            Text("En UDP seulement sur cet équipement.").font(Theme.caption).foregroundStyle(Theme.warning)
        } else if step.transport == .tcp, !store.syslogTCPEnabled {
            Text("Activez «\u{00A0}Recevoir aussi en TCP\u{00A0}» dans les récepteurs ci-dessus.").font(Theme.caption).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        commandBlock(step.commands, help: step.isInterfacePath ? "Copier le chemin" : "Copier les commandes")
        if let verify = step.verify {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Vérifier").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary).fixedSize()
                Text(verify)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { ToolActions.copy(verify) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Copier la commande de vérification")
            }
        }
        if let note = step.note {
            Text(note).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var trapGuide: some View {
        let list = LogDeviceCommands.traps(mac: macAddress, port: store.trapPort)
        let chosen = list[min(example, list.count - 1)]
        Picker("Équipement", selection: $example) {
            ForEach(Array(list.enumerated()), id: \.offset) { index, item in
                Text(item.title).tag(index)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        commandBlock(chosen.text, help: "Copier les commandes")
    }

    private func commandBlock(_ text: String, help: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.consoleText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.console))
            Button { ToolActions.copy(text) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.consoleMuted)
            .padding(8)
            .help(help)
        }
    }

    // MARK: Transfert (note 78)

    private var forwardPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonHeading("Transfert vers un autre serveur")
                Spacer(minLength: 6)
                Toggle("Transférer", isOn: $store.forward.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Relayer les messages reçus vers un SIEM ou le serveur Syslog du client")
            }
            if store.forward.enabled {
                HStack(spacing: 6) {
                    TextField("Serveur (10.10.0.40 ou siem.client.local)", text: $store.forward.host)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(12))
                    TextField("514", text: $forwardPortText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(12))
                        .frame(width: 58)
                        .onChange(of: forwardPortText) { _, value in
                            if let port = UInt16(value.trimmingCharacters(in: .whitespaces)), port > 0 { store.forward.port = port }
                        }
                        .help("Port du serveur de destination (514 en général)")
                }
                HStack(spacing: 8) {
                    Picker("Transport", selection: $store.forward.transport) {
                        ForEach(SyslogTransport.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("UDP\u{00A0}: un datagramme par message. TCP\u{00A0}: connexion gardée ouverte, cadrage par longueur (RFC\u{00A0}6587).")
                    Picker("Gravité", selection: $store.forward.minimumSeverity) {
                        ForEach(LogSeverity.allCases) { severity in
                            Text(severity == .debug ? "Toutes les gravités" : "Gravité " + severity.atLeastLabel).tag(severity)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                ToolCheckbox(label: "Inclure les traps SNMP (converties en Syslog RFC\u{00A0}5424)", isOn: $store.forward.includeTraps)
                forwardState
            }
            Text("Les messages Syslog reçus sont relayés tels quels, avec leur heure et leur émetteur d’origine. Désactivé par défaut\u{00A0}; le transfert suit la réception (il démarre et s’arrête avec elle).")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    @ViewBuilder private var forwardState: some View {
        let status = store.forwardStatus
        if let problem = store.forwardProblem {
            Text(problem).font(Theme.caption).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if store.isForwarding {
            HStack(spacing: 6) {
                Chip(text: store.forward.transport == .tcp && !status.connected && status.sent == 0 ? "En attente" : "Transfert actif",
                     tone: status.lastError == nil ? .success : .warning, systemImage: "arrow.turn.up.right")
                Text("\(LogFormat.count(status.sent, "message relayé", "messages relayés"))" + (status.dropped > 0 ? " · \(status.dropped) perdu\(status.dropped > 1 ? "s" : "")" : "")
                     + " vers \(store.forward.destinationLabel)")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = status.lastError {
                Text(error).font(Theme.caption).foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Prêt\u{00A0}: le transfert vers \(store.forward.destinationLabel) démarrera avec la réception.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: FortiGate

    private var fortiGatePanel: some View {
        let ids = store.controllerIDs(forKeys: keys)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonHeading("Journaux de la FortiGate")
                Spacer(minLength: 6)
                if store.isReadingFortiGate { ProgressView().controlSize(.small) }
            }
            if ids.isEmpty {
                Text("Aucune FortiGate pour les sites affichés\u{00A0}: ajoutez-la dans Réglages › Switchs › Contrôleurs FortiGate.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(ids, id: \.self) { id in
                    fortiRow(id)
                }
            }
            HStack(spacing: 6) {
                Text("Emplacement").font(Theme.small).foregroundStyle(Theme.text).fixedSize()
                Picker("Emplacement", selection: $store.fortiStorage) {
                    ForEach(FortiLogStorage.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            Button {
                store.readFortiGate(keys: keys, since: since, until: until)
            } label: {
                Label("Lire les journaux de la période", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            .disabled(!store.canReadFortiGate(keys: keys) || store.isReadingFortiGate)
            Text("Événements système, VPN, utilisateurs et Wi-Fi, en lecture seule (GET /api/v2/log/…/event/…). Droit «\u{00A0}Log & Report\u{00A0}» en lecture nécessaire au profil de l’administrateur API.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    private func fortiRow(_ id: UUID) -> some View {
        let name = fortigate.controller(id)?.displayName ?? "FortiGate"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(store.fortiErrors[id] != nil ? Theme.criticalBadge : (store.fortiLastRead[id] != nil ? Theme.successDot : Theme.neutralDot))
                    .frame(width: 7, height: 7)
                Text(name).font(Theme.bodyMedium).lineLimit(1)
                Spacer(minLength: 4)
                if let read = store.fortiLastRead[id] {
                    Text("lu à \(LogFormat.time(read).prefix(5))" + (store.fortiStorageUsed[id].map { $0 == "disk" ? " · disque" : " · mémoire" } ?? ""))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                } else {
                    Text("pas encore lue").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            if let error = store.fortiErrors[id] {
                Text(error).font(Theme.caption).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.fortiNotes[id] ?? [], id: \.self) { note in
                Text(note).font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Conservation

    private var retentionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonHeading("Conservation")
            HStack(spacing: 6) {
                Picker("Messages", selection: Binding(get: { store.retention.maxMessages },
                                                      set: { store.retention = LogRetention(maxMessages: $0, maxDays: store.retention.maxDays) })) {
                    ForEach(LogRetention.messageChoices, id: \.self) { Text("\(LogJournal.groupedLabel($0))\u{00A0}messages").tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                Text("ou").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Picker("Jours", selection: Binding(get: { store.retention.maxDays },
                                                   set: { store.retention = LogRetention(maxMessages: store.retention.maxMessages, maxDays: $0) })) {
                    ForEach(LogRetention.dayChoices, id: \.self) { Text("\($0)\u{00A0}jour\($0 > 1 ? "s" : "")").tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            Text("\(LogFormat.count(store.journal.count, "message gardé", "messages gardés")) sur ce Mac, tous sites confondus. Les plus anciens partent d’abord.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }
}

/// Style de bouton choisi à l'exécution (principal ou secondaire).
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
