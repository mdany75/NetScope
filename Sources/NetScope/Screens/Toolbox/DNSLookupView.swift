import NetScopeCore
import SwiftUI

@MainActor
final class ToolDNSModel: ObservableObject {
    @Published var query = ""
    @Published var type: DNSRecordType = .a
    /// Serveur choisi ; nil = résolveur du système.
    @Published var server: IPv4Address?
    @Published var customServer = ""
    @Published var useCustom = false
    @Published private(set) var isRunning = false
    @Published private(set) var result: DNSLookupResult?
    @Published var error: String?

    var effectiveServer: IPv4Address? { useCustom ? IPv4Address(customServer) : server }

    func run(store: ToolStore) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { error = "Saisir un nom ou une adresse."; return }
        if useCustom && IPv4Address(customServer) == nil {
            error = "Serveur DNS invalide (adresse IPv4 attendue)."
            return
        }
        let type = self.type
        let server = effectiveServer
        error = nil
        isRunning = true
        store.record(command: DNSLookup.command(for: text, type: type, server: server))
        Task {
            do {
                let result = try await DNSLookup.resolve(text, type: type, server: server)
                self.result = result
                let first = result.records.first.map { "\($0.typeLabel) \($0.value)" } ?? result.rcode
                store.record(ToolRecent(tool: .dns, target: text, summary: first,
                                        status: result.rcode == "NOERROR" ? .ok : .warning))
            } catch {
                self.result = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                store.record(ToolRecent(tool: .dns, target: text, summary: self.error ?? "Échec", status: .failure))
            }
            self.isRunning = false
        }
    }
}

/// Recherche DNS (A, AAAA, MX, PTR, TXT, NS, CNAME) sur le serveur choisi.
struct DNSLookupView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: ToolDNSModel
    @ObservedObject var store: ToolStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: "Nom ou adresse") {
                    ToolTextField(placeholder: "WKS346.bureau.local, 10.182.122.111…", text: $model.query) { model.run(store: store) }
                }
                ToolLabeledField(label: "Serveur DNS") {
                    HStack(spacing: 6) {
                        serverMenu
                        if model.useCustom {
                            ToolTextField(placeholder: "9.9.9.9", text: $model.customServer,
                                          invalid: !model.customServer.isEmpty && IPv4Address(model.customServer) == nil)
                                .frame(width: 130)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                Button(model.isRunning ? "Résolution…" : "Résoudre") { model.run(store: store) }
                    .buttonStyle(.primary)
                    .disabled(model.isRunning)
            }
            HStack(spacing: 4) {
                ForEach(DNSRecordType.queryable) { type in
                    ToolChoiceChip(label: type.rawValue, isSelected: model.type == type) {
                        model.type = type
                        if !model.query.isEmpty { model.run(store: store) }
                    }
                }
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if let result = model.result {
                ToolTable(columns: [.init(title: "Nom", width: 260), .init(title: "Type", width: 70),
                                    .init(title: "TTL", width: 70, alignment: .trailing), .init(title: "Valeur")]) {
                    if result.records.isEmpty {
                        Text("Aucun enregistrement.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    ForEach(Array(result.records.enumerated()), id: \.offset) { _, record in
                        ToolTableRow {
                            Text(record.name).font(Theme.mono(12)).toolCell(260)
                            Chip(text: record.typeLabel, tone: .accent, mono: true).toolCell(70)
                            Text(verbatim: String(record.ttl)).font(Theme.mono(12)).toolCell(70, alignment: .trailing)
                            Text(record.value).font(Theme.mono(12, weight: .medium)).textSelection(.enabled)
                                .help(record.value).toolCell(nil)
                        }
                    }
                }
                Text(result.summary).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                if let device = matchingDevice(result) {
                    Button("Ouvrir la fiche de \(device.displayName) →") { state.showDevice(device.id) }
                        .buttonStyle(.ghost)
                }
            } else if model.error == nil {
                Text("Sans serveur choisi, la requête passe par le résolveur de macOS (mêmes réponses que les applications). Une adresse IP en PTR est convertie en nom in-addr.arpa.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            // Nom d'hôte de l'appareil choisi s'il est un nom DNS valide, sinon son adresse en PTR.
            if model.query.isEmpty, let device = state.selectedDevice {
                if let host = device.hostname, host.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil {
                    model.query = host
                } else {
                    model.query = device.ip.description
                    model.type = .ptr
                }
            }
        }
    }

    private var serverOptions: [(String, IPv4Address)] {
        var list: [(String, IPv4Address)] = []
        if let gateway = state.activeInterface?.gateway { list.append(("\(gateway) (passerelle)", gateway)) }
        for server in state.dnsServers where !list.contains(where: { $0.1 == server }) {
            list.append(("\(server) (DNS du réseau)", server))
        }
        for (name, text) in [("Cloudflare", "1.1.1.1"), ("Google", "8.8.8.8"), ("Quad9", "9.9.9.9")] {
            if let ip = IPv4Address(text), !list.contains(where: { $0.1 == ip }) { list.append(("\(text) (\(name))", ip)) }
        }
        return list
    }

    private var serverMenu: some View {
        let label = model.useCustom ? "Autre serveur" : (model.server.map { server in
            serverOptions.first { $0.1 == server }?.0 ?? server.description
        } ?? "Résolveur du système")
        return Menu {
            Button("Résolveur du système") { model.server = nil; model.useCustom = false }
            Divider()
            ForEach(serverOptions, id: \.1) { option in
                Button(option.0) { model.server = option.1; model.useCustom = false }
            }
            Divider()
            Button("Autre serveur…") { model.useCustom = true }
        } label: {
            Text(label).font(Theme.mono(12))
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .frame(width: 230, height: 34)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    private func matchingDevice(_ result: DNSLookupResult) -> Device? {
        let values = result.records.map(\.value) + [model.query]
        return state.devices.first { device in
            values.contains(device.ip.description) || values.contains { value in
                guard let host = device.hostname, !host.isEmpty else { return false }
                return value.lowercased().hasPrefix(host.lowercased())
            }
        }
    }
}
