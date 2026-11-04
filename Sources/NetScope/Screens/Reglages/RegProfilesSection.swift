import NetScopeCore
import SwiftUI

/// Réglages › Profils de scan : profil par défaut et réglages du profil Personnalisé
/// (threads, délai, tentatives, ports), enregistrés dans UserDefaults pour le Scanner.
struct RegProfilesSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var prefs = RegPrefs.shared

    private var tuning: RegScanTuning { prefs.tuning }

    var body: some View {
        RegPanel(title: "Profils de scan",
                 subtitle: "Cliquez sur un profil pour en faire le profil par défaut du Scanner. Le profil Personnalisé se règle ci-dessous.") {
            // Quatre cartes côte à côte ; deux par ligne en petite fenêtre.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(ScanProfile.allCases) { profile in
                    profileCard(profile)
                }
            }
            RegMethodsPanel().padding(.top, 14)
            customPanel.padding(.top, 14)
        }
    }

    // MARK: Cartes

    /// Étiquettes d'après les méthodes du profil (ce que le Scanner fera vraiment) et ses ports.
    private func tags(for profile: ScanProfile) -> [String] {
        var options = ScanOptions(profile: profile, customPorts: tuning.ports)
        options.methods = prefs.methods(for: profile)
        let plan = ScanPlan(options: options, autoDiscoverSwitches: prefs.autoDiscoverSwitches)
        var tags = options.methods.tags.filter { $0 != "SNMP" }
        let count = profile.ports(custom: tuning.ports).count
        tags.append(profile == .complet ? "\(count) ports TCP" : "TCP \(count) ports")
        if plan.snmp { tags.append("SNMP") }
        if let index = tags.firstIndex(of: "LLDP/CDP") { tags.append(tags.remove(at: index)) }
        return tags
    }

    private func detail(for profile: ScanProfile) -> String {
        profile == .personnalise
            ? "\(tuning.threads) threads · \(tuning.timeoutMs) ms · \(tuning.retries) tentative(s)"
            : profile.summary
    }

    private func profileCard(_ profile: ScanProfile) -> some View {
        let selected = prefs.defaultProfile == profile
        return Button {
            prefs.defaultProfile = profile
            state.scanProfile = profile
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile.label).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    Spacer(minLength: 4)
                    if selected {
                        Text("PAR DÉFAUT").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent))
                    }
                }
                Text(detail(for: profile)).font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                RegFlowLayout(spacing: 4) {
                    ForEach(tags(for: profile), id: \.self) { tag in
                        Text(tag).font(Theme.mono(10, weight: .medium)).foregroundStyle(Theme.neutralText).fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.neutralSoft))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(selected ? Theme.accentSoft : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(selected ? Theme.accent : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Profil Personnalisé

    /// Estimation grossière pour un /24, reprise du croquis.
    private var estimate: String {
        let ports = Double(tuning.ports.count)
        let seconds = max(1, (254 * (1 + ports * 0.3) * Double(max(tuning.timeoutMs, 50)) * (1 + Double(tuning.retries)) * 0.35
            / Double(max(tuning.threads, 1)) / 1000).rounded(.up).clampedInt)
        let text = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        return "≈ \(text) estimé pour un /24"
    }

    private var tokens: [(text: String, valid: Bool)] {
        RegScanTuning.tokens(tuning.portsText).map { ($0, ScanProfile.parsePorts($0) != nil) }
    }

    private var portSummary: String {
        let invalid = tokens.filter { !$0.valid }.count
        var text = "\(tuning.ports.count) port(s) TCP"
        if invalid > 0 { text += " · \(invalid) entrée(s) invalide(s) ignorée(s)" }
        if tokens.count > 24 { text += " · \(tokens.count - 24) autres non affichés" }
        return text
    }

    private var customPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PROFIL PERSONNALISÉ").font(Theme.captionSemibold).kerning(0.55).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(estimate).font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.accentStrong)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    threadsControl
                    HStack(spacing: 12) {
                        RegField(label: "Délai d’attente (ms)") {
                            Stepper(value: $prefs.tuning.timeoutMs, in: 50...10_000, step: 50) {
                                RegTextField(placeholder: "400", text: intBinding(\.timeoutMs, range: 50...10_000), mono: true)
                                    .frame(width: 90)
                            }
                        }
                        RegField(label: "Tentatives") {
                            Stepper(value: $prefs.tuning.retries, in: 0...5) {
                                RegTextField(placeholder: "1", text: intBinding(\.retries, range: 0...5), mono: true)
                                    .frame(width: 60)
                            }
                        }
                    }
                    portsControl
                    Text("Ces réglages sont enregistrés tout de suite ; le Scanner les lit pour le profil Personnalisé. Ses méthodes de découverte se choisissent ci-dessus.")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var threadsControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Threads simultanés").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(tuning.threads)").font(Theme.mono(12, weight: .semibold))
            }
            RegSlider(value: Binding(get: { Double(tuning.threads) },
                                     set: { prefs.tuning.threads = min(512, max(1, Int($0.rounded()))) }),
                      range: 1...512)
            HStack {
                Text("1"); Spacer(); Text("128"); Spacer(); Text("256"); Spacer(); Text("384"); Spacer(); Text("512")
            }
            .font(Theme.mono(10)).foregroundStyle(Theme.textTertiary)
            if tuning.threads > 256 {
                Text("Au-delà de 256 threads, certains switchs et pare-feu limitent le débit ARP/ICMP : risque de faux « sans réponse ».")
                    .font(Theme.small).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var portsControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ports TCP à sonder").font(.system(size: 12, weight: .semibold))
            RegTextField(placeholder: "22, 80, 443, 8000-8010", text: $prefs.tuning.portsText, mono: true,
                         invalid: tokens.contains { !$0.valid })
            FlowTokens(tokens: Array(tokens.prefix(24)))
            Text(portSummary).font(Theme.small).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Button("Ports courants") { prefs.tuning.portsText = ScanProfile.commonPorts.map(String.init).joined(separator: ",") }
                Button("Caméras et IoT") { prefs.tuning.portsText = "80,443,554,1883,5000,8000,8080,8443,8883,37777" }
                Button("Par défaut") { prefs.tuning.portsText = RegScanTuning.defaultPorts }
            }
            .buttonStyle(RegSmallButtonStyle())
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<RegScanTuning, Int>, range: ClosedRange<Int>) -> Binding<String> {
        Binding(get: { String(prefs.tuning[keyPath: keyPath]) }, set: { text in
            if let value = Int(text.filter(\.isNumber)) { prefs.tuning[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, value)) }
        })
    }
}

/// Jetons de ports (valides en gris, invalides en orange), sur plusieurs lignes.
private struct FlowTokens: View {
    let tokens: [(text: String, valid: Bool)]

    var body: some View {
        RegFlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token.text)
                    .font(Theme.mono(11))
                    .foregroundStyle(token.valid ? Theme.neutralText : Theme.warning)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(token.valid ? Theme.neutralSoft : Theme.warningSoft))
            }
        }
    }
}

/// Disposition en lignes successives (les éléments passent à la ligne au besoin).
struct RegFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: min(maxX, width), height: subviews.isEmpty ? 0 : y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
