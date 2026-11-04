import NetScopeCore
import SwiftUI

// Petits composants de l'écran Réglages, d'après le croquis : interrupteur 36 × 20,
// sélecteur segmenté, tuiles clé-valeur, champs à bordure grise.

/// Section de contenu : panneau blanc, titre 15 pt gras, sous-titre gris, accessoire à droite.
struct RegPanel<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(Theme.panelTitle).foregroundStyle(Theme.text)
                        if let subtitle {
                            Text(subtitle).font(Theme.body).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
                .padding(.bottom, 14)
                content
            }
        }
    }
}

extension RegPanel where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// Intertitre 11 pt majuscules (« LANGUE DE L’INTERFACE »).
struct RegLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .kerning(0.55)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Interrupteur natif de macOS (petite taille), à la couleur d'accent du système.
struct RegSwitch: View {
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(!isEnabled)
    }
}

/// Ligne « libellé + description + interrupteur », séparée par un filet #F3F4F6.
struct RegToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var isEnabled = true
    /// Fonction à venir : puce « Bientôt », interrupteur désactivé.
    var soon = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.bodySemibold).foregroundStyle(Theme.text)
                    if soon { Chip(text: "Bientôt", tone: .neutral) }
                }
                if let detail {
                    Text(detail).font(Theme.small).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RegSwitch(isOn: $isOn, isEnabled: isEnabled && !soon)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutralSoft).frame(height: 1) }
    }
}

/// Sélecteur segmenté du croquis (fond #F9FAFB, segment actif blanc bordé d'accent).
struct RegSegmented<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
        var enabled = true
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Theme.accentStrong : (option.enabled ? Theme.neutralText : Theme.textTertiary.opacity(0.7)))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.panel : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Theme.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!option.enabled)
                .help(option.enabled ? option.label : "\(option.label) : bientôt")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
        .fixedSize()
    }
}

/// Tuile clé-valeur (« Version installée · NetScope 1.0.0 »), fond #F9FAFB.
struct RegTile<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            value.font(Theme.bodySemibold).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Rangée de tuiles : côte à côte, puis sur plusieurs lignes quand la fenêtre est étroite
/// (au lieu de tronquer les valeurs).
struct RegTileRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
            content
        }
    }
}

extension RegTile where Value == Text {
    init(_ title: String, _ value: String, mono: Bool = false) {
        self.title = title
        self.value = Text(value).font(mono ? Theme.mono(12, weight: .semibold) : Theme.bodySemibold)
    }
}

/// Champ de saisie à bordure grise (30 pt), texte normal ou monospace.
struct RegTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var secure = false
    var invalid = false

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? Theme.mono(12) : Theme.small)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(invalid ? Theme.critical : Theme.border))
    }
}

/// Champ avec son libellé au-dessus (12 pt semi-gras).
struct RegField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            content
        }
    }
}

/// Bandeau de message (info, succès, alerte, erreur), coins 6.
struct RegNotice<Trailing: View>: View {
    let text: String
    var tone: Tone = .accent
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(text)
                .font(Theme.small)
                .foregroundStyle(tone == .neutral ? Theme.neutralText : tone.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tone == .neutral ? Theme.panelMuted : tone.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(tone == .neutral ? Theme.border : Color.clear))
    }
}

extension RegNotice where Trailing == EmptyView {
    init(_ text: String, tone: Tone = .accent) {
        self.init(text: text, tone: tone) { EmptyView() }
    }
}

/// Puce arrondie d'état (« Installée », « Vérifiée »).
struct RegPill: View {
    let text: String
    var tone: Tone = .success

    var body: some View {
        Text(text)
            .font(Theme.captionSemibold)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.background))
            .fixedSize()
    }
}

/// Petit bouton secondaire (24–26 pt) pour les actions en ligne.
struct RegSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(configuration.isPressed ? Theme.panelMuted : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
            .contentShape(Rectangle())
    }
}

extension View {
    /// Désactive la commande et l'estompe (les styles de bouton du thème ne le font pas).
    func regDisabled(_ disabled: Bool) -> some View {
        self.disabled(disabled).opacity(disabled ? 0.5 : 1)
    }
}

/// Curseur natif de macOS, à la couleur d'accent du système.
struct RegSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Slider(value: $value, in: range)
            .controlSize(.small)
            .labelsHidden()
    }
}

enum RegFormat {
    /// « 18,4 Mo » (unités décimales, virgule française).
    static func megabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_000_000
        return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",") + "\u{00A0}Mo"
    }

    /// « 28 oct. 2026 »
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "fr_CA")))
    }

    /// « aujourd’hui 09:02 », « hier 16:42 » ou « 28 oct. 2026, 09:02 ».
    static func moment(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "fr_FR")))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "aujourd’hui \(time)" }
        if calendar.isDateInYesterday(date) { return "hier \(time)" }
        return "\(day(date)), \(time)"
    }

    /// « 65 536 » avec espace fine insécable.
    static func count(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result.append("\u{202F}") }
            result.append(character)
        }
        return result
    }
}
