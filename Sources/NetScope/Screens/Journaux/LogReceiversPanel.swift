import NetScopeCore
import SwiftUI

/// Panneau de droite de l'écran Journaux : récepteurs Syslog et traps de ce Mac (ports, état,
/// arrêt automatique, coupe-feu), commandes à régler sur les équipements, lecture des journaux de
/// la FortiGate et conservation du journal.
struct LogReceiversPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = LogStore.shared
    @ObservedObject private var fortigate = FortiGateStore.shared
    let keys: [String]
    let since: Date
    let until: Date?
    @State private var syslogText = ""
    @State private var trapText = ""
    @State private var example = 0
    @State private var exampleKind = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            receivers
            commands
            fortiGatePanel
            retentionPanel
        }
        .onAppear {
            syslogText = String(store.syslogPort)
            trapText = String(store.trapPort)
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
                        text: $syslogText, listening: store.syslogListening, error: store.syslogError,
                        count: store.receivedCount[.syslog] ?? 0, standard: 514) { store.syslogPort = $0 }
            receiverRow(title: "Traps SNMP", detail: "v1 et v2c, informs acquittés", enabled: $store.trapsEnabled,
                        text: $trapText, listening: store.trapListening, error: store.trapError,
                        count: store.receivedCount[.trap] ?? 0, standard: 162) { store.trapPort = $0 }
            ToolCheckbox(label: "N’accepter que la communauté des Identifiants", isOn: $store.checkCommunity)
                .disabled(store.isListening)
                .help("La communauté reste au Trousseau (Réglages › Identifiants) et n’est jamais écrite dans le journal.")
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
            Text("Ports au-dessus de 1024 par défaut\u{00A0}: aucun droit administrateur n’est nécessaire. Les ports standard (514 et 162) demandent les droits root sur certains Mac\u{00A0}: réglez plutôt le port de NetScope sur l’équipement (commandes ci-dessous). Certains équipements n’envoient leurs traps que vers le port 162.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
    }

    static func autoStopLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Jamais"
        case let m where m >= 60: return "Après \(m / 60)\u{00A0}h"
        default: return "Après \(minutes)\u{00A0}min"
        }
    }

    private func receiverRow(title: String, detail: String, enabled: Binding<Bool>, text: Binding<String>, listening: Bool,
                             error: String?, count: Int, standard: UInt16, apply: @escaping (UInt16) -> Void) -> some View {
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
                Text("UDP").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .frame(width: 62)
                    .disabled(store.isListening)
                    .onSubmit { commit(text, apply: apply) }
                    .onChange(of: text.wrappedValue) { _, _ in commit(text, apply: apply) }
                    .help("Port UDP d’écoute (standard\u{00A0}: \(standard))")
            }
            HStack(spacing: 6) {
                if listening {
                    Chip(text: "En écoute", tone: .success, systemImage: "dot.radiowaves.left.and.right")
                    Text(LogFormat.count(count, "message reçu", "messages reçus"))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
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

    // MARK: Commandes des équipements

    private var macAddress: String { state.activeInterface?.address.description ?? "<adresse du Mac>" }

    private var commands: some View {
        let list = exampleKind == 0 ? LogDeviceCommands.syslog(mac: macAddress, port: store.syslogPort)
            : LogDeviceCommands.traps(mac: macAddress, port: store.trapPort)
        let chosen = list[min(example, list.count - 1)]
        return VStack(alignment: .leading, spacing: 8) {
            MonHeading("À régler sur l’équipement")
            HStack(spacing: 8) {
                Picker("Type", selection: $exampleKind) {
                    Text("Syslog").tag(0)
                    Text("Traps").tag(1)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: exampleKind) { _, _ in example = 0 }
                Picker("Équipement", selection: $example) {
                    ForEach(Array(list.enumerated()), id: \.offset) { index, item in
                        Text(item.title).tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            ZStack(alignment: .topTrailing) {
                Text(chosen.text)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.consoleText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.console))
                Button { ToolActions.copy(chosen.text) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.consoleMuted)
                .padding(8)
                .help("Copier les commandes")
            }
            Text("Adresse de ce Mac\u{00A0}: \(macAddress). Les messages sont rattachés au site actif («\u{00A0}\(SiteModel.shared.activeName)\u{00A0}») au moment de leur réception.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monPanel()
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
