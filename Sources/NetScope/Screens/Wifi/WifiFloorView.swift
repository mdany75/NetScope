import NetScopeCore
import SwiftUI

/// Note 94 : onglet « Relevé sur plan » de l'écran Wi-Fi. Plan de l'étage (PDF ou image importés),
/// échelle par deux points et une distance, mesures au clic, carte de chaleur de la mesure choisie,
/// zones mortes, chevauchements de canaux, borne suggérée et bornes placées à la main.
struct WifiFloorView: View {
    @ObservedObject var wifi: WifiStore
    @ObservedObject private var store = WifiFloorStore.shared
    @ObservedObject private var sites = SiteModel.shared
    @ObservedObject private var fortiAP = FortiAPStore.shared
    @State private var scaleText = ""
    @State private var renameText = ""
    @State private var renaming = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = store.message {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 12, weight: .semibold))
                    Text(message).font(Theme.small)
                    Spacer()
                    Button { store.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain)
                        .help("Fermer le message")
                }
                .foregroundStyle(Theme.accentStrong)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.accentSoft))
            }
            if store.isReadOnly {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold))
                    Text("Relevé sur plan de ce site illisible (version plus récente de NetScope\u{00A0}?)\u{00A0}: lecture seule, rien n’est importé, mesuré ni enregistré.")
                        .font(Theme.small)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.warning.opacity(0.12)))
            }
            if let floor = store.floor {
                controls(floor)
                if let computed = store.computed, computed.floorID == floor.id {
                    SidePanelSplit(sideWidth: 300, collapse: .below) {
                        planPanel(floor, computed: computed)
                    } side: {
                        VStack(spacing: 14) {
                            summaryPanel(floor, computed: computed)
                            measuresPanel(floor)
                        }
                    }
                } else {
                    Panel {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Calcul de la carte de chaleur…").font(Theme.small).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
            } else {
                emptyState
            }
        }
        .onAppear { store.load(siteKey: sites.activeKey) }
        .onChange(of: sites.activeKey) { _, key in store.load(siteKey: key) }
        .alert("Renommer l’étage", isPresented: $renaming) {
            TextField("Nom", text: $renameText)
            Button("Renommer") { store.rename(renameText) }
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog("Supprimer l’étage «\u{00A0}\(store.floor?.name ?? "")\u{00A0}», son plan et ses mesures\u{00A0}?",
                            isPresented: $confirmDelete) {
            Button("Supprimer l’étage", role: .destructive) { store.removeFloor() }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var emptyState: some View {
        Panel {
            VStack(spacing: 10) {
                Image(systemName: "map").font(.system(size: 28)).foregroundStyle(Theme.textTertiary)
                Text("Aucun plan pour ce site").font(Theme.bodySemibold)
                Text("Importer le plan d’un étage (PDF ou image), indiquer l’échelle, puis cliquer sur le plan à l’endroit où l’on se trouve pour mesurer le Wi-Fi.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button { store.importPlan() } label: { Label("Importer un plan…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.primary)
                    .disabled(store.isReadOnly)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    // MARK: Commandes

    private func controls(_ floor: WifiFloor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Une ligne en grande fenêtre, deux en petite.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    floorAndTool(floor)
                    Spacer(minLength: 0)
                    metricAndNeighbors
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { floorAndTool(floor); Spacer(minLength: 0) }
                    HStack(spacing: 10) { metricAndNeighbors; Spacer(minLength: 0) }
                }
            }
            toolHint(floor)
        }
    }

    @ViewBuilder private func floorAndTool(_ floor: WifiFloor) -> some View {
        Picker("Étage", selection: Binding(get: { store.floor?.id }, set: { store.selectedFloorID = $0 })) {
            ForEach(store.plans.floors) { item in Text(item.name).tag(Optional(item.id)) }
        }
        .fixedSize()
        Menu {
            Button("Ajouter un étage (importer un plan)…") { store.importPlan() }
            Button("Renommer l’étage…") { renameText = floor.name; renaming = true }
            Divider()
            Button("Supprimer l’étage…", role: .destructive) { confirmDelete = true }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Étages du site")
            .disabled(store.isReadOnly)
        Picker("Outil", selection: $store.tool) {
            ForEach(WifiFloorTool.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(store.isReadOnly)
    }

    @ViewBuilder private var metricAndNeighbors: some View {
        Picker("Afficher", selection: $store.metric) {
            ForEach(WifiHeatMetric.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        Toggle("Bornes voisines", isOn: $store.withNeighbors)
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("Balaye aussi les bornes voisines à chaque mesure (quelques secondes de plus) pour repérer les chevauchements de canaux.")
    }

    @ViewBuilder private func toolHint(_ floor: WifiFloor) -> some View {
        HStack(spacing: 8) {
            switch store.tool {
            case .measure:
                Image(systemName: "hand.point.up.left").foregroundStyle(Theme.textSecondary)
                Text(store.phase ?? (floor.scale == nil
                    ? "Plan sans échelle (largeur supposée de \(Int(WifiFloor.assumedWidthMetres))\u{00A0}m)\u{00A0}: choisir «\u{00A0}Échelle\u{00A0}» pour l’indiquer. Cliquer sur le plan à l’endroit où l’on se trouve pour mesurer."
                    : "Cliquer sur le plan à l’endroit où l’on se trouve\u{00A0}: signal, bruit, débit, borne et canal sont lus par ce Mac."))
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                if store.isMeasuring { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Annuler la dernière mesure") { store.removeLastMeasure() }
                    .buttonStyle(.ghost)
                    .disabled(floor.measures.isEmpty || store.isMeasuring)
            case .scale:
                Image(systemName: "ruler").foregroundStyle(Theme.textSecondary)
                if store.scalePending != nil {
                    Text("Distance réelle entre les deux points\u{00A0}:").font(Theme.small)
                    TextField("m", text: $scaleText).frame(width: 70).textFieldStyle(.roundedBorder)
                    Text("m").font(Theme.small)
                    Button("Appliquer") { store.applyScale(metres: Self.metres(scaleText) ?? 0) }
                        .buttonStyle(.primary)
                        .disabled((Self.metres(scaleText) ?? 0) <= 0)
                    Button("Annuler") { store.cancelScale() }.buttonStyle(.secondary)
                } else {
                    Text(store.scaleFirst == nil ? "Cliquer le premier point d’une distance connue (un mur, une porte)." : "Cliquer le second point.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            case .ap:
                Image(systemName: "wifi.router").foregroundStyle(Theme.textSecondary)
                let names = fortiAP.shownOverview.aps.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                if !names.isEmpty {
                    Menu("FortiAP") {
                        ForEach(names, id: \.self) { name in Button(name) { store.apName = name } }
                    }
                    .fixedSize()
                    .help("Bornes lues sur la FortiGate du site")
                }
                TextField("Nom de la borne", text: $store.apName).frame(width: 180).textFieldStyle(.roundedBorder)
                Text("puis cliquer sur le plan à son emplacement (un second clic la déplace).").font(Theme.small).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    static func metres(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    // MARK: Plan

    private func planPanel(_ floor: WifiFloor, computed: WifiFloorComputed) -> some View {
        Panel(padding: 10) {
            GeometryReader { geo in
                WifiFloorPlanDrawing(floor: floor, metric: computed.metric, analysis: computed.analysis, heat: computed.heat,
                                     scaleFirst: store.scaleFirst, scalePending: store.scalePending)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        store.tap(WifiPlanPoint(x: location.x / geo.size.width, y: location.y / geo.size.height), wifi: wifi)
                    }
                    .contextMenu {
                        ForEach(floor.aps) { ap in
                            Button("Retirer la borne «\u{00A0}\(ap.name)\u{00A0}»") { store.removeAP(ap.id) }
                        }
                    }
            }
            .aspectRatio(floor.imageWidth / floor.imageHeight, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        }
    }

    // MARK: Panneaux

    private func summaryPanel(_ floor: WifiFloor, computed: WifiFloorComputed) -> some View {
        let analysis = computed.analysis
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Bilan de l’étage")
                Text(WifiHeatmap.summary(analysis)).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                if analysis.measureCount > 0 {
                    HStack(spacing: 8) {
                        tile("\(Int(analysis.goodPercent.rounded()))\u{00A0}%", "≥ −67\u{00A0}dBm", analysis.goodPercent >= 80 ? Theme.success : Theme.warning)
                        tile("\(analysis.deadZones.count)", analysis.deadZones.count > 1 ? "zones mortes" : "zone morte",
                             analysis.deadZones.isEmpty ? Theme.success : Theme.critical)
                        tile(analysis.medianRSSI.map { "\($0)" } ?? "—", "dBm médian", Theme.text)
                    }
                }
                ForEach(Array(WifiHeatmap.distinctOverlaps(analysis.overlaps).prefix(4).enumerated()), id: \.offset) { _, item in
                    finding("exclamationmark.triangle.fill", Theme.warning,
                            "Canal \(item.overlap.channel) (\(item.overlap.band.label)) partagé avec " + item.overlap.others.joined(separator: ", ")
                                + " (jusqu’à \(item.overlap.strongestRSSI)\u{00A0}dBm" + (item.places > 1 ? ", \(item.places) endroits)" : ")"))
                }
                if analysis.suggestion != nil {
                    finding("plus.diamond", Theme.accentStrong, "Borne suggérée au centre de la plus grande zone faible (losange sur le plan).")
                }
                if floor.measures.contains(where: { $0.neighbors != nil }) == false, analysis.measureCount > 0 {
                    finding("info.circle", Theme.textSecondary, "Chevauchements non vérifiés\u{00A0}: cocher «\u{00A0}Bornes voisines\u{00A0}» pendant les mesures.")
                }
                Divider()
                SectionHeader(computed.metric.label)
                WifiFloorLegend(metric: computed.metric, labels: computed.heat.labels)
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(color)
            Text(label).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
    }

    private func finding(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
            Text(text).font(Theme.small).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func measuresPanel(_ floor: WifiFloor) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("Mesures", subtitle: "\(floor.measures.count)")
                if floor.measures.isEmpty {
                    Text("Aucune mesure sur cet étage.").font(Theme.small).foregroundStyle(Theme.textSecondary)
                }
                ForEach(floor.measures.suffix(8).reversed()) { measure in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.heatColor(.signal, value: Double(measure.rssi))).frame(width: 8, height: 8)
                        Text(WifiText.timeSeconds(measure.time)).font(Theme.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                        Text("\(measure.rssi)\u{00A0}dBm").font(Theme.small).monospacedDigit()
                        Text([measure.apLabel, measure.channel.map { "canal \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contextMenu {
                        Button("Supprimer la mesure", role: .destructive) { store.removeMeasures([measure.id]) }
                    }
                }
                if !floor.aps.isEmpty {
                    Divider()
                    SectionHeader("Bornes placées", subtitle: "\(floor.aps.count)")
                    ForEach(floor.aps) { ap in
                        HStack(spacing: 6) {
                            Image(systemName: "wifi.router").font(.system(size: 11)).foregroundStyle(Theme.accent)
                            Text(ap.name).font(Theme.small)
                            if let model = ap.model { Text(model).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
                            Spacer(minLength: 0)
                        }
                        .contextMenu { Button("Retirer du plan", role: .destructive) { store.removeAP(ap.id) } }
                    }
                }
            }
        }
    }
}
