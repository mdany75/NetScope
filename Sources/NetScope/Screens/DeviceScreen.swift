import NetScopeCore
import SwiftUI

/// Écran `Screen.appareil` : fiche de l'appareil choisi (croquis docs/croquis/Device.dc.html).
struct DeviceScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var inventory = InvModel.shared

    var body: some View {
        if let device = state.selectedDevice {
            // Type choisi à la main (note 20) à la place du type détecté.
            DeviceDetailView(device: inventory.withManualTypes([device])[0])
                .id(device.id)
        } else {
            EmptyState(systemImage: Screen.appareil.symbol, title: "Aucun appareil sélectionné",
                       message: "Choisissez un appareil dans le Scanner ou l’Inventaire pour afficher sa fiche\u{00A0}: réseau, matériel, emplacement physique, ports, page web et notes.") {
                Button("Ouvrir le Scanner") { state.open(.scanner) }.buttonStyle(.primary)
            }
        }
    }
}

private struct DeviceDetailView: View {
    @EnvironmentObject private var state: AppState
    let device: Device
    @ObservedObject private var session = DeviceSession.shared
    @ObservedObject private var store = ToolStore.shared
    @ObservedObject private var notes = DeviceNotesStore.shared
    /// Emplacements relevés (note 18) : un ancien relevé est grisé comme dans le Scanner.
    @ObservedObject private var switches = SwitchStore.shared
    @State private var nameDraft = ""
    @State private var copied: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                tabBar
                switch session.tab {
                case .apercu:
                    DeviceOverviewTab(device: device) { scanPorts() }
                case .ports:
                    DevicePortsTab(device: device, model: session.portModel(for: device), store: store)
                case .web:
                    DeviceWebTab(device: device, model: session.webModel(for: device), store: store)
                case .historique:
                    DeviceHistoryTab(device: device, store: store)
                case .notes:
                    DeviceNotesTab(device: device, notes: notes)
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { nameDraft = device.customName ?? "" }
        .screenToolbar {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.secondary).help("Appareil précédent").disabled(neighbor(-1) == nil)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.secondary).help("Appareil suivant").disabled(neighbor(1) == nil)
            Button {
                copy(sheet, label: "Fiche copiée")
            } label: {
                Label("Copier la fiche", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.secondary)
        }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.accentSoft)
                    Image(systemName: device.deviceType.toolSymbol)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        TextField("", text: $nameDraft, prompt: Text(device.hostnameLabel ?? device.ip.description).foregroundStyle(Theme.textTertiary))
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .focused($nameFocused)
                            .onSubmit(commitName)
                            .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                            .fixedSize()
                            .help("Nom personnalisé (vide : nom d’hôte)")
                        Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        statusChip
                    }
                    metaRow
                    HStack(spacing: 6) {
                        Menu {
                            DeviceTypeMenuItems(devices: [device])
                        } label: {
                            HStack(spacing: 4) {
                                Chip(text: device.deviceType.label, tone: .accent, systemImage: device.deviceType.toolSymbol)
                                if InvModel.shared.typeChoice(for: state.device(withID: device.id) ?? device).isManual {
                                    ManualTypeMark()
                                }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Type de l’appareil\u{00A0}: cliquez pour le changer")
                        if let vlan = device.vlan {
                            let status = state.vlanStatus(device)
                            Chip(text: "VLAN \(vlan)", tone: .neutral).opacity(status.isCurrent ? 1 : 0.5).help(status.explanation ?? "")
                        }
                        if let range = device.rangeLabel { Chip(text: range, tone: .neutral) }
                        if device.mac?.isRandomized == true { Chip(text: "MAC privée", tone: .warning) }
                        if let port = device.switchLocation {
                            let status = state.locationStatus(device)
                            Chip(text: port, tone: .neutral, mono: true, systemImage: "cable.connector")
                                .opacity(status.isCurrent ? 1 : 0.5).help(status.explanation ?? "")
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            actions
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            StatusDot(online: device.isOnline, size: 7)
            Text(device.isOnline
                 ? "En ligne" + (device.latencyMs.map { " · \(ToolFormat.milliseconds($0))" } ?? "")
                 : "Hors ligne · vu \(ToolText.relative(device.lastSeen))")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(device.isOnline ? Theme.success : Theme.neutralText)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(device.isOnline ? Theme.successSoft : Theme.neutralSoft))
        .fixedSize()
    }

    /// Hostname, IP, MAC… : passent à la ligne en petite fenêtre au lieu d'être tronqués.
    private var metaRow: some View {
        FlowLayout(spacing: 16, lineSpacing: 4) {
            if let host = device.hostnameLabel { meta("Hostname", host + (device.nameSourceLabel.map { " · \($0)" } ?? "")) }
            meta("IP", device.ip.description)
            if let mac = device.mac { meta("MAC", mac.formatted(.upperColon)) }
            Text(device.vendorLabel).lineLimit(1)
            Text("Vu \(ToolText.relative(device.lastSeen))").lineLimit(1)
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textSecondary)
    }

    private func meta(_ key: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
        .lineLimit(1)
    }

    /// Boutons d'action ; en petite fenêtre, ils passent à la ligne au lieu d'être tronqués.
    private var actions: some View {
        SwitchFlowLayout(spacing: 8, lineSpacing: 8) {
            Button {
                state.sendToPing(device.ip.description)
            } label: {
                Label("Ping continu", systemImage: Screen.ping.symbol)
            }
            .buttonStyle(.primary)
            Button { scanPorts() } label: { Label("Scanner les ports", systemImage: "door.left.hand.open") }
                .buttonStyle(.secondary)
            Button {
                let wol = store.wol
                if let mac = device.mac { wol.macText = mac.formatted(.upperColon) }
                if wol.broadcastText.isEmpty { wol.broadcastText = WakeOnLAN.defaultBroadcast(for: state.activeInterface).description }
                store.open(.wol, in: state)
            } label: {
                Label("Wake-on-LAN", systemImage: "power")
            }
            .buttonStyle(.secondary)
            .disabled(device.mac == nil)
            Button { ToolActions.open(DeviceSession.defaultURL(for: device)) } label: {
                Label("Ouvrir dans le navigateur", systemImage: "safari")
            }
            .buttonStyle(.secondary)
            Button { ToolActions.open("ssh://\(device.ip)") } label: { Label("SSH", systemImage: "terminal") }
                .buttonStyle(.secondary)
                .help("Ouvre ssh://\(device.ip.description) dans Terminal")
            Menu {
                Button("Adresse IP") { copy(device.ip.description, label: "IP copiée") }
                if let mac = device.mac {
                    Button("Adresse MAC") { copy(mac.formatted(.upperColon), label: "MAC copiée") }
                }
                if let host = device.hostname { Button("Nom d’hôte") { copy(host, label: "Nom copié") } }
                Divider()
                Button("Fiche complète") { copy(sheet, label: "Fiche copiée") }
            } label: {
                Label(copied ?? "Copier", systemImage: copied == nil ? "doc.on.doc" : "checkmark")
                    .font(Theme.bodyMedium)
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 12)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Onglets

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(DeviceTab.allCases) { tab in
                let selected = session.tab == tab
                Button { session.tab = tab } label: {
                    HStack(spacing: 6) {
                        Text(tab.label)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                        if let count = count(for: tab) {
                            Text("\(count)")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Theme.neutralSoft))
                                .overlay(Capsule().strokeBorder(Theme.border))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? Theme.accent : Color.clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func count(for tab: DeviceTab) -> Int? {
        switch tab {
        case .ports:
            let model = session.portModel(for: device)
            let count = model.summary?.open.count ?? device.openPorts.count
            return count > 0 ? count : nil
        case .historique:
            let keys = [device.ip.description, device.mac?.formatted(.upperColon) ?? "", device.hostname ?? ""]
            return 1 + store.recents(matching: keys).count + (device.lastSeen.timeIntervalSince(device.firstSeen) > 60 ? 1 : 0)
        default:
            return nil
        }
    }

    // MARK: Actions

    private func scanPorts() {
        session.tab = .ports
        DevicePortsTab.start(session.portModel(for: device), device: device, state: state, store: store)
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (device.customName ?? "") else { return }
        state.setCustomName(trimmed, for: device.id)
    }

    private func copy(_ text: String, label: String) {
        ToolActions.copy(text)
        copied = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = nil }
    }

    private func neighbor(_ offset: Int) -> Device? {
        guard let index = state.devices.firstIndex(where: { $0.id == device.id }) else { return nil }
        let target = index + offset
        return state.devices.indices.contains(target) ? state.devices[target] : nil
    }

    private func step(_ offset: Int) {
        if let next = neighbor(offset) { state.selectedDeviceID = next.id }
    }

    /// Fiche en texte (presse-papiers).
    private var sheet: String {
        var lines = ["\(device.displayName) — \(device.ip)"]
        func add(_ key: String, _ value: String?) { if let value, !value.isEmpty { lines.append("\(key)\u{00A0}: \(value)") } }
        add("Nom d’hôte", device.hostname)
        add("MAC", device.mac?.formatted(.upperColon))
        add("Fabricant", device.vendorLabel)
        add("Famille", device.deviceType.label)
        add("État", device.isOnline ? "en ligne" : "hors ligne")
        add("Latence", device.latencyMs.map(ToolFormat.milliseconds))
        add("Emplacement", device.switchLocation)
        add("VLAN", device.vlan.map(String.init))
        add("Plage", device.rangeLabel)
        add("Ports ouverts", device.openPorts.isEmpty ? nil : device.openPorts.map(String.init).joined(separator: ", "))
        add("Première détection", DeviceFormat.date(device.firstSeen))
        add("Dernière détection", DeviceFormat.date(device.lastSeen))
        let note = notes.note(for: device)
        if !note.isEmpty { lines += ["", "Notes\u{00A0}:", note] }
        return lines.joined(separator: "\n")
    }
}
