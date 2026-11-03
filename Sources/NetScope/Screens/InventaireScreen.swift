import NetScopeCore
import SwiftUI

/// Vues sauvegardées de l'inventaire.
enum InvView: String, CaseIterable, Hashable {
    case tous, nonIdentifies, disparus, favoris

    var label: String {
        switch self {
        case .tous: return "Tous"
        case .nonIdentifies: return "Non identifiés"
        case .disparus: return "Disparus > 30 j"
        case .favoris: return "Favoris"
        }
    }

    func includes(_ record: InvRecord, now: Date) -> Bool {
        switch self {
        case .tous: return true
        case .nonIdentifies: return record.isUnidentified
        case .disparus: return record.isGone(now: now)
        case .favoris: return record.annotations.isFavorite
        }
    }
}

/// Écran `Screen.inventaire` : base permanente des appareils, fiche éditable et chronologie
/// (croquis docs/croquis/Inventaire.dc.html).
struct InventaireScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var model = InvModel.shared

    @State private var view: InvView = .tous
    @State private var sort: InvSortKey = .derniere
    @State private var ascending = false
    @State private var mergeOpen = false
    @State private var ignoredDuplicates: Set<String> = []
    @State private var importing = false
    @State private var exportDocument: InvCSVDocument?
    @State private var exporting = false

    var body: some View {
        let now = Date()
        let records = model.store.sortedRecords
        let rows = sorted(records.filter { view.includes($0, now: now) && $0.matches(state.searchText) })
        let duplicates = model.store.probableDuplicates().filter { !ignoredDuplicates.contains($0.id) }
        let selected = model.record(model.selectedKey) ?? rows.first

        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(now: now)
                    tiles(records, now: now)
                    if mergeOpen { mergePanel(duplicates) }
                    InvTable(rows: rows, total: records.count, width: geometry.size.width - Theme.contentPadding * 2,
                             selectedKey: selected?.key, sort: $sort, ascending: $ascending, now: now,
                             onSelect: { model.selectedKey = $0 }, onFavorite: { model.toggleFavorite($0) })
                    if let selected {
                        InvDetail(record: selected, events: model.store.events(for: selected.key), now: now)
                            .id(selected.key)
                    }
                    help
                }
                .padding(Theme.contentPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .screenToolbar {
            Button { importing = true } label: { Label("Importer CSV", systemImage: "square.and.arrow.down") }
                .buttonStyle(.secondary)
            Button {
                exportDocument = InvCSVDocument(text: InvCSV.export(rows))
                exporting = true
            } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
            Button { mergeOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Label("Fusionner les doublons", systemImage: "arrow.triangle.merge")
                    if !duplicates.isEmpty {
                        Text("\(duplicates.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accentStrong)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Color.white))
                    }
                }
            }
            .buttonStyle(.primary)
        }
        .feedsInventory(state)
        .onAppear {
            if model.selectedKey == nil || model.record(model.selectedKey) == nil {
                let fromScanner = state.selectedDeviceID.flatMap(IPv4Address.init).flatMap { model.store.record(forIP: $0) }
                model.selectedKey = fromScanner?.key ?? rows.first?.key
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            switch result {
            case .success(let url):
                do {
                    model.show(model.importCSV(try InvFiles.readText(url)))
                } catch {
                    model.show("Lecture impossible : \(error.localizedDescription)")
                }
            case .failure(let error):
                model.show("Import annulé : \(error.localizedDescription)")
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "inventaire-\(InvFormat.day(Date())).csv") { result in
            if case .success(let url) = result {
                model.show("Export CSV : \(url.lastPathComponent) (\(rows.count) lignes)")
            }
        }
    }

    // MARK: En-tête

    private func header(now: Date) -> some View {
        HStack(spacing: 12) {
            InvSegmented(options: InvView.allCases.map { ($0, $0.label) }, selection: $view)
            Text(mergeCaption(now: now))
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let toast = model.toast { InvToast(text: toast) }
        }
    }

    private func mergeCaption(now: Date) -> String {
        guard let last = model.store.lastMerge else {
            return "Base permanente de tous les appareils jamais vus · aucun scan fusionné pour l’instant"
        }
        let when = InvFormat.relative(last, now: now)
        return "Base permanente de tous les appareils jamais vus · dernier scan fusionné "
            + (when == "À l’instant" ? "à l’instant" : when.replacingOccurrences(of: "Il y a", with: "il y a"))
    }

    // MARK: Tuiles

    private func tiles(_ records: [InvRecord], now: Date) -> some View {
        let today = Calendar.current.startOfDay(for: now)
        let seenToday = records.filter { $0.lastSeen >= today }.count
        let online = records.filter(\.isOnline).count
        let unidentified = records.filter(\.isUnidentified).count
        let gone = records.filter { $0.isGone(now: now) }.count
        let conflicts = model.store.conflictIPs.sorted()

        return HStack(alignment: .top, spacing: 12) {
            InvTile(title: "Appareils connus", value: "\(records.count)", subtitle: "Toutes plages confondues") { view = .tous }
            InvTile(title: "Vus aujourd’hui", value: "\(seenToday)", subtitle: "\(online) en ligne au dernier scan",
                    valueColor: Theme.success)
            InvTile(title: "Non identifiés", value: "\(unidentified)", subtitle: "MAC aléatoire ou empreinte insuffisante",
                    valueColor: Theme.warning) { view = .nonIdentifies }
            InvTile(title: "Disparus", value: "\(gone)", subtitle: "Sans réponse depuis plus de 30 jours",
                    valueColor: Theme.textSecondary) { view = .disparus }
            InvTile(title: "Alertes d’inventaire", value: "") {
                VStack(alignment: .leading, spacing: 5) {
                    if conflicts.isEmpty {
                        Text("Aucun conflit IP actif").font(Theme.small).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(conflicts.prefix(3), id: \.self) { ip in
                        Button {
                            model.selectedKey = model.store.record(forIP: ip)?.key
                        } label: {
                            HStack(spacing: 6) {
                                Text("CONFLIT IP").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.critical)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.criticalSoft))
                                Text(ip.description).font(Theme.mono(12)).foregroundStyle(Theme.text)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Doublons

    private func mergePanel(_ duplicates: [InvDuplicate]) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Doublons probables",
                              subtitle: duplicates.isEmpty ? "Aucun doublon restant"
                                  : "\(duplicates.count) paire\(duplicates.count > 1 ? "s" : "") détectée\(duplicates.count > 1 ? "s" : "") sur \(model.store.count) fiches") {
                    Button("Fermer") { mergeOpen = false }.buttonStyle(.secondary)
                }
                ForEach(duplicates) { pair in
                    if let keep = model.record(pair.keep), let other = model.record(pair.absorb) {
                        HStack(alignment: .top, spacing: 12) {
                            duplicateCard("Fiche conservée", keep)
                            duplicateCard("Fiche à rattacher", other)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Critères : " + pair.reason)
                                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button("Fusionner dans .\(keep.ip.octets.3)") {
                                        model.absorb(pair)
                                        model.show("Fiches fusionnées : \(other.displayName) rattaché à \(keep.ip)")
                                    }
                                    .buttonStyle(.primary)
                                    Button("Ignorer") { ignoredDuplicates.insert(pair.id) }.buttonStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func duplicateCard(_ title: String, _ record: InvRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Text(record.displayName).font(Theme.bodySemibold)
            Text("\(record.ip.description) · \(record.mac?.formatted(.upperColon) ?? "—") · vu \(InvFormat.relative(record.lastSeen).lowercased())")
                .font(Theme.mono(11)).foregroundStyle(Theme.neutralText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }

    // MARK: Aide

    private var help: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Theme.textSecondary)
            (Text("Identification par empreinte : ").foregroundStyle(Theme.text).fontWeight(.semibold)
             + Text("préfixe OUI de la MAC, nom d’hôte et ports ouverts relevés par le scan. Un appareil à MAC aléatoire reste « non identifié » jusqu’à ce qu’un technicien confirme sa fiche (en lui donnant un nom). Les fiches sont enregistrées dans ~/Library/Application Support/NetScope/inventory.json."))
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Tri

    private func sorted(_ records: [InvRecord]) -> [InvRecord] {
        records.sorted { a, b in
            let order: Bool
            switch sort {
            case .nom:
                let result = a.displayName.localizedStandardCompare(b.displayName)
                if result == .orderedSame { return a.ip < b.ip }
                order = result == .orderedAscending
            case .ip:
                if a.ip == b.ip { return a.key < b.key }
                order = a.ip < b.ip
            case .premiere:
                if a.firstSeen == b.firstSeen { return a.ip < b.ip }
                order = a.firstSeen < b.firstSeen
            case .derniere:
                if a.lastSeen == b.lastSeen { return a.ip < b.ip }
                order = a.lastSeen < b.lastSeen
            }
            return ascending ? order : !order
        }
    }
}
