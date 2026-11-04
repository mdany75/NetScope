import SwiftUI

// Composants réutilisables par tous les écrans. Disposition des croquis, couleurs du système :
// panneaux sur fond système à bordure fine, intertitres en petites majuscules, valeurs techniques
// en SF Mono. Tout suit le mode clair ou sombre.

/// Ton d'une puce, d'une pastille ou d'un message.
enum Tone {
    case neutral, accent, success, warning, critical

    var foreground: Color {
        switch self {
        case .neutral: return Theme.neutralText
        case .accent: return Theme.accentStrong
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Theme.neutralSoft
        case .accent: return Theme.accentSoft
        case .success: return Theme.successSoft
        case .warning: return Theme.warningSoft
        case .critical: return Theme.criticalSoft
        }
    }

    /// Couleur vive d'une pastille d'état.
    var dot: Color {
        switch self {
        case .neutral: return Theme.neutralDot
        case .accent: return Theme.accent
        case .success: return Theme.successDot
        case .warning: return Theme.warningDot
        case .critical: return Theme.criticalBadge
        }
    }
}

// MARK: - Panneau

/// Panneau sur fond système (blanc en clair, gris foncé en sombre), bordure fine.
struct Panel<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Intertitre de section : 11 pt, majuscules, gris ; accessoire facultatif à droite.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title.uppercased())
                .font(Theme.captionSemibold)
                .kerning(0.5)
                .foregroundStyle(Theme.textSecondary)
            if let subtitle {
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Ligne clé-valeur (« Passerelle   10.182.122.1 »). `mono` : valeur en SF Mono.
struct KeyValueRow: View {
    let key: String
    let value: String
    var mono: Bool = false
    var keyWidth: CGFloat = 130

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(Theme.small)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: keyWidth, alignment: .leading)
            Text(value)
                .font(mono ? Theme.mono(12) : Theme.small)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Puces et pastilles

/// Puce (étiquette colorée) : « Nouveau », « VLAN 30 », « Conflit IP »…
struct Chip: View {
    let text: String
    var tone: Tone = .neutral
    var mono: Bool = false
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(mono ? Theme.mono(11, weight: .semibold) : Theme.captionSemibold)
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(tone.background))
        .fixedSize()
    }
}

/// Synonyme français de `Chip`.
typealias Puce = Chip

/// Puce de filtre cliquable (« Tous 214 », « En ligne », « Nouveaux »…).
struct FilterChip: View {
    let title: String
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Theme.bodyMedium)
                if let count {
                    Text("\(count)").font(Theme.mono(11, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.onAccent.opacity(0.85) : Theme.textSecondary)
                }
            }
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(isSelected ? Theme.accent : Theme.panel))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Pastille d'état ronde (en ligne, hors ligne, alerte).
struct StatusDot: View {
    var tone: Tone = .success
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(tone.dot).frame(width: size, height: size)
    }
}

extension StatusDot {
    /// Pastille verte si en ligne, grise sinon.
    init(online: Bool, size: CGFloat = 8) {
        self.init(tone: online ? .success : .neutral, size: size)
    }
}

/// Étiquette de port ouvert, avec le nom du service quand il est connu (« 443 https »).
struct PortTag: View {
    let port: UInt16
    var showService: Bool = false
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            Text("\(port)").font(Theme.mono(11, weight: .semibold))
            if showService, let name = PortTag.serviceName(port) {
                Text(name).font(Theme.caption)
            }
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: Theme.chipRadius).fill(tone.background))
        .fixedSize()
    }

    /// Nom usuel des ports les plus courants.
    static func serviceName(_ port: UInt16) -> String? {
        switch port {
        case 21: return "ftp"
        case 22: return "ssh"
        case 23: return "telnet"
        case 25: return "smtp"
        case 53: return "dns"
        case 80: return "http"
        case 88: return "kerberos"
        case 135: return "msrpc"
        case 139: return "netbios"
        case 161: return "snmp"
        case 389: return "ldap"
        case 443: return "https"
        case 445: return "smb"
        case 515: return "lpd"
        case 541: return "fortinet"
        case 554: return "rtsp"
        case 631: return "ipp"
        case 3306: return "mysql"
        case 3389: return "rdp"
        case 5900: return "vnc"
        case 8080: return "http-alt"
        case 8443: return "https-alt"
        case 9100: return "jetdirect"
        default: return nil
        }
    }
}

/// Pastille de compteur dans la barre latérale ou un onglet.
struct CountBadge: View {
    let count: Int
    var color: Color = Theme.accent

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(color))
            .fixedSize()
    }
}

// MARK: - Tableaux

/// En-tête de tableau : 11 pt, majuscules, gris, fond légèrement teinté.
struct TableHeader: View {
    struct Column: Identifiable {
        let id = UUID()
        let title: String
        var width: CGFloat? = nil
        var alignment: Alignment = .leading
    }

    let columns: [Column]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                let label = Text(column.title.uppercased())
                    .font(Theme.captionSemibold)
                    .kerning(0.3)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                if let width = column.width {
                    label.frame(width: width, alignment: column.alignment)
                } else {
                    label.frame(maxWidth: .infinity, alignment: column.alignment)
                }
            }
        }
        .frame(height: 32)
        .background(Theme.panelMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Graphiques

/// Petite courbe (latence, débit…). Les valeurs nil laissent un trou (paquet perdu).
struct Sparkline: View {
    let values: [Double?]
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 1.5
    /// Remplit la zone sous la courbe.
    var filled: Bool = true

    var body: some View {
        GeometryReader { geometry in
            let present = values.compactMap { $0 }
            let maxValue = max(present.max() ?? 1, 0.0001)
            let minValue = min(present.min() ?? 0, 0)
            let span = max(maxValue - minValue, 0.0001)
            let stepX = values.count > 1 ? geometry.size.width / CGFloat(values.count - 1) : 0
            let point: (Int, Double) -> CGPoint = { index, value in
                CGPoint(x: CGFloat(index) * stepX,
                        y: geometry.size.height - CGFloat((value - minValue) / span) * geometry.size.height)
            }
            ZStack {
                if filled {
                    Path { path in
                        for run in Sparkline.runs(values) {
                            guard let first = run.first, let last = run.last else { continue }
                            path.move(to: CGPoint(x: point(first.0, first.1).x, y: geometry.size.height))
                            for (index, value) in run { path.addLine(to: point(index, value)) }
                            path.addLine(to: CGPoint(x: point(last.0, last.1).x, y: geometry.size.height))
                            path.closeSubpath()
                        }
                    }
                    .fill(color.opacity(0.12))
                }
                Path { path in
                    for run in Sparkline.runs(values) {
                        guard let first = run.first else { continue }
                        path.move(to: point(first.0, first.1))
                        for (index, value) in run.dropFirst() { path.addLine(to: point(index, value)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Suites de valeurs consécutives non nulles.
    static func runs(_ values: [Double?]) -> [[(Int, Double)]] {
        var result: [[(Int, Double)]] = []
        var current: [(Int, Double)] = []
        for (index, value) in values.enumerated() {
            if let value {
                current.append((index, value))
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Barre de progression fine (6 pt), à la couleur d’accent.
struct ProgressBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(color).frame(width: geometry.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - États vides

/// Message centré quand il n'y a rien à afficher.
struct EmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
            Text(title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
            if let message {
                Text(message)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            actions.padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Écran en construction

/// Écran provisoire : ce que l'écran fera, d'après son croquis (docs/croquis/).
struct UnderConstructionView: View {
    let screen: Screen
    let summary: String
    /// Blocs prévus, dans l'ordre du croquis.
    let features: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Panel(padding: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Theme.accentSoft)
                            Image(systemName: screen.symbol)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(screen.pageTitle).font(Theme.panelTitle).foregroundStyle(Theme.text)
                                Chip(text: "En construction", tone: .warning, systemImage: "hammer.fill")
                            }
                            Text(summary)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Croquis de référence : docs/croquis/\(screen.sketchFile)")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("Prévu sur cet écran")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "circle.dashed")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .padding(.top, 2)
                                    Text(feature)
                                        .font(Theme.body)
                                        .foregroundStyle(Theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
                                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
                            }
                        }
                    }
                }
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Petite fenêtre

/// Contenu principal et panneau de droite à largeur fixe (détail, éditeur, réglages de l'écran).
/// Le panneau défile de haut en bas quand il est plus haut que la place disponible (`scrolls`).
/// Quand la largeur disponible passe sous `collapseBelow`, le panneau se replie : en mode
/// `.overlay`, le bouton « Afficher le panneau » de la barre d'outils le fait apparaître par-dessus
/// le contenu ; en mode `.below` (écrans qui défilent déjà), il passe sous le contenu principal.
struct SidePanelSplit<Main: View, Side: View>: View {
    enum Collapse { case overlay, below }

    var sideWidth: CGFloat
    var collapse: Collapse = .overlay
    var spacing: CGFloat = 14
    /// Largeur disponible sous laquelle le panneau se replie (par défaut : panneau + 520 pt).
    var collapseBelow: CGFloat? = nil
    /// Met le panneau dans une vue qui défile verticalement (à éviter s'il défile déjà lui-même).
    var scrolls = true
    /// Libellé du bouton qui affiche le panneau replié.
    var title = "Panneau de détail"
    /// Côte à côte (mode `.below`) : le contenu principal prend la hauteur du panneau s'il est
    /// moins haut (pas de vide entre ce bloc et le suivant). Le contenu doit pouvoir s'étirer.
    var matchesHeight = false
    /// Affichage du panneau replié piloté par l'écran (qui a déjà son propre bouton) : aucun
    /// bouton « Afficher le panneau » n'est ajouté à la barre d'outils.
    var presented: Binding<Bool>? = nil
    @ViewBuilder var main: Main
    @ViewBuilder var side: Side

    @State private var width: CGFloat = .infinity
    @State private var showSide = false

    private var compact: Bool { width < (collapseBelow ?? sideWidth + 520) }

    var body: some View {
        if collapse == .below {
            belowLayout
        } else {
            overlayLayout
        }
    }

    private var widthReader: some View {
        WidthReader(width: $width)
    }

    /// Panneau sous le contenu quand la place manque (pas de bouton, rien de caché).
    private var belowLayout: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: spacing) {
                    main.frame(maxWidth: .infinity, alignment: .top)
                    side.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if matchesHeight {
                HStack(alignment: .top, spacing: spacing) {
                    main.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    side.frame(minWidth: 0, idealWidth: sideWidth, maxWidth: sideWidth, maxHeight: .infinity, alignment: .top)
                        .layoutPriority(1)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: spacing) {
                    main.frame(maxWidth: .infinity, alignment: .top)
                    side.frame(minWidth: 0, idealWidth: sideWidth, maxWidth: sideWidth).layoutPriority(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(widthReader)
    }

    private var overlayLayout: some View {
        HStack(alignment: .top, spacing: spacing) {
            main.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !compact {
                // Largeur minimale nulle : le panneau n'impose pas sa largeur au filet de sécurité de
                // la petite fenêtre (sinon il ne se replierait jamais) ; il garde sa largeur en priorité.
                sidePanel
                    .frame(minWidth: 0, idealWidth: sideWidth, maxWidth: sideWidth)
                    .layoutPriority(1)
            }
        }
        .background(widthReader)
        .overlay(alignment: .topTrailing) {
            if compact && isSideShown {
                sidePanel
                    .frame(width: sideWidth)
                    .padding(10)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: Theme.panelRadius + 4)
                        .fill(Theme.appBackground)
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 6))
                    .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius + 4).strokeBorder(Theme.border))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: isSideShown)
        .toolbar {
            if compact && presented == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSide.toggle()
                    } label: {
                        Label(showSide ? "Masquer le panneau" : "Afficher le panneau", systemImage: "sidebar.right")
                            .labelStyle(.iconOnly)
                    }
                    .help(showSide ? "Masquer « \(title) »" : "Afficher « \(title) »")
                }
            }
        }
    }

    private var isSideShown: Bool { presented?.wrappedValue ?? showSide }

    @ViewBuilder private var sidePanel: some View {
        if scrolls {
            ScrollView(.vertical) {
                side.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            side
        }
    }
}

/// Lit la largeur de la vue qu'il habille (en arrière-plan) et la range dans `width`.
/// Pas de préférence partagée : un SidePanelSplit ou un AdaptiveStack imbriqué dans un autre ne
/// fausse pas la largeur lue par son parent (sinon la mise en page bascule sans fin).
private struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, newWidth in width = newWidth }
        }
    }
}

/// Filet de sécurité de la petite fenêtre : l'écran reçoit toute la place disponible, mais jamais
/// moins que sa taille minimale ; s'il ne tient pas, il défile (horizontalement ou verticalement)
/// au lieu d'être coupé ou d'agrandir la fenêtre.
struct MinimumSizeScroller<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                AtLeastLayout(size: geometry.size) { content }
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        }
    }
}

/// Donne à son contenu la taille proposée, ou sa taille minimale si elle est plus grande.
private struct AtLeastLayout: Layout {
    var size: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return size }
        // Un écran qui tient dans la place proposée la prend telle quelle ; sinon (il répond plus
        // grand que proposé), il garde sa taille minimale et la vue défile. La hauteur est vérifiée
        // à la largeur retenue (un texte qui passe à la ligne n'a pas la même hauteur partout).
        var width = size.width
        if subview.sizeThatFits(ProposedViewSize(size)).width > size.width + 0.5 {
            width = max(size.width, subview.sizeThatFits(ProposedViewSize(width: 0, height: size.height)).width)
        }
        var height = size.height
        if subview.sizeThatFits(ProposedViewSize(width: width, height: size.height)).height > size.height + 0.5 {
            height = max(size.height, subview.sizeThatFits(ProposedViewSize(width: width, height: 0)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Côte à côte quand la largeur disponible atteint `breakpoint`, l'un sous l'autre sinon
/// (petite fenêtre). Le contenu est donné une fois ; seul l'agencement change.
struct AdaptiveStack<Content: View>: View {
    var breakpoint: CGFloat
    var spacing: CGFloat = 16
    var horizontalAlignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    @State private var width: CGFloat = .infinity

    var body: some View {
        let layout = width >= breakpoint
            ? AnyLayout(HStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        layout { content }
            // Largeur minimale nulle : la largeur mesurée décide de l'agencement, sans que l'agencement
            // côte à côte n'impose sa propre largeur minimale (sinon il ne passerait jamais en colonne).
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(WidthReader(width: $width))
    }
}

/// Éléments en ligne qui passent à la ligne suivante quand la largeur manque (légendes, puces).
/// Chaque élément garde sa taille idéale : un libellé n'est jamais coupé en deux.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width.isFinite ? min(maxX, width) : maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
