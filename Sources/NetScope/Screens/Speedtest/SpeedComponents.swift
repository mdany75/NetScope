import SwiftUI

// Petits composants de l'écran Speedtest, d'après le croquis.

/// Couleur de la montée (cyan foncé du croquis).
let speedUpColor = Color(light: 0x0E7490, dark: 0x8FDEF4)
let speedUpSoft = Color(light: 0xCFFAFE, dark: 0x1B4C50)
let speedDownSoft = Color(light: 0xDBEAFE, dark: 0x1B3250)

/// Bouton segmenté : fond bleu pâle et bordure accent quand il est choisi.
struct SpeedSegment: View {
    let label: String
    let isOn: Bool
    var isEnabled = true
    var mono = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(mono ? Theme.mono(12, weight: .medium) : .system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isOn ? Theme.accentStrong : (isEnabled ? Theme.text : Theme.textTertiary))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(isOn ? Theme.accentSoft : Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .strokeBorder(isOn ? Theme.accent : Theme.border))
                .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// Rangée de segments de même largeur.
struct SpeedSegmentRow<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var disabled: Set<Value> = []
    var mono = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, label in
                SpeedSegment(label: label, isOn: selection == value, isEnabled: !disabled.contains(value), mono: mono) {
                    selection = value
                }
                .help(disabled.contains(value) ? "Bientôt" : "")
            }
        }
    }
}

/// Petit intertitre de champ (11 pt, majuscules).
struct SpeedFieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.captionSemibold)
            .kerning(0.4)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Champ texte aux couleurs du croquis.
struct SpeedTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono = true

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(12) : Theme.small)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.border))
    }
}

/// Tuile de résultat : intitulé, grande valeur, unité, ligne de détail.
struct SpeedTile: View {
    let label: String
    let value: String
    let unit: String
    let detail: String
    var badge: String? = nil
    var badgeTone: Tone = .success

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.captionSemibold)
                .kerning(0.4)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(Theme.mono(22, weight: .semibold)).foregroundStyle(Theme.text)
                Text(unit).font(Theme.small).foregroundStyle(Theme.textSecondary)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(badgeTone.foreground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(badgeTone.background))
                }
            }
            // Deux lignes au besoin (tuiles étroites) plutôt qu'un texte tronqué.
            Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panelMuted))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }
}

/// Pastille d'état arrondie avec point (barre d'outils, étapes).
struct SpeedStatusPill: View {
    let text: String
    let tone: Tone
    var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            SpeedPulseDot(color: tone == .neutral ? Color(hex: 0x9CA3AF) : tone.foreground, pulsing: pulsing)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(tone.background))
        .fixedSize()
    }
}

/// Point qui pulse pendant une mesure.
struct SpeedPulseDot: View {
    let color: Color
    var pulsing = false
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulsing && dim ? 0.35 : 1)
            .onAppear { updateAnimation() }
            .onChange(of: pulsing) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if pulsing {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
        } else {
            dim = false
        }
    }
}

/// Message en bandeau (alerte orange, succès vert, information grise).
struct SpeedBanner: View {
    let text: String
    var tone: Tone = .warning
    var systemImage: String = "exclamationmark.triangle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)).padding(.top, 1)
            Text(text).font(Theme.small).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone == .warning ? Color(light: 0x9A3412, dark: 0xF2AA91) : tone.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(tone.background))
    }
}

/// Barre horizontale de comparaison (forfait, filaire contre Wi-Fi).
struct SpeedBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.border)
                RoundedRectangle(cornerRadius: 4).fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension View {
    /// Désactive et estompe (les styles de bouton du thème ne changent pas d'aspect seuls).
    func speedDisabled(_ disabled: Bool) -> some View {
        self.disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}
