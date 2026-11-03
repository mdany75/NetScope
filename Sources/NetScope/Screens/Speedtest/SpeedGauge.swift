import SwiftUI

/// Grande jauge circulaire (arc de 270°) du croquis : piste grise, arc coloré, graduations,
/// aiguille et valeur au centre. `value` est animée (Animatable).
struct SpeedGauge: View, Animatable {
    var value: Double
    let scale: Double
    let color: Color
    let phase: String
    let valueText: String
    let unit: String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    // Repère du croquis : boîte 300 × 250, centre (150, 150).
    private static let box = CGSize(width: 300, height: 250)
    private static let center = CGPoint(x: 150, y: 150)
    private static let radius: CGFloat = 112
    private static let labelRadius: CGFloat = 87
    private static let startAngle = 135.0
    private static let sweep = 270.0

    var body: some View {
        Canvas { context, size in
            let ratio = min(size.width / SpeedGauge.box.width, size.height / SpeedGauge.box.height)
            context.translateBy(x: (size.width - SpeedGauge.box.width * ratio) / 2, y: (size.height - SpeedGauge.box.height * ratio) / 2)
            context.scaleBy(x: ratio, y: ratio)
            let fraction = min(max(value / max(scale, 1), 0), 1)

            context.stroke(SpeedGauge.arc(from: 0, to: 1), with: .color(Theme.border),
                           style: StrokeStyle(lineWidth: 16, lineCap: .round))
            if fraction > 0.002 {
                context.stroke(SpeedGauge.arc(from: 0, to: fraction), with: .color(color),
                               style: StrokeStyle(lineWidth: 16, lineCap: .round))
            }
            // Graduations : 5 grandes, 4 petites entre chacune.
            var ticks = Path()
            for index in 0...25 {
                let angle = SpeedGauge.angle(Double(index) / 25)
                let major = index % 5 == 0
                ticks.move(to: SpeedGauge.point(angle, SpeedGauge.radius - 14))
                ticks.addLine(to: SpeedGauge.point(angle, SpeedGauge.radius - (major ? 22 : 18)))
            }
            context.stroke(ticks, with: .color(Color(hex: 0x9CA3AF)), lineWidth: 1.4)
            for index in 0...5 {
                let mark = scale * Double(index) / 5
                let position = SpeedGauge.point(SpeedGauge.angle(Double(index) / 5), SpeedGauge.labelRadius - 8)
                context.draw(Text(SpeedGauge.markLabel(mark)).font(Theme.mono(11)).foregroundColor(Theme.textSecondary),
                             at: position)
            }
            // Aiguille et repère sur l'arc.
            let needleAngle = SpeedGauge.angle(fraction)
            var needle = Path()
            needle.move(to: SpeedGauge.center)
            needle.addLine(to: SpeedGauge.point(needleAngle, SpeedGauge.radius - 30))
            context.stroke(needle, with: .color(Theme.text), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 145, y: 145, width: 10, height: 10)), with: .color(Theme.text))
            let dot = SpeedGauge.point(needleAngle, SpeedGauge.radius)
            let dotRect = CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: dotRect), with: .color(.white))
            context.stroke(Path(ellipseIn: dotRect), with: .color(color), lineWidth: 3)

            context.draw(Text(phase).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSecondary),
                         at: CGPoint(x: 150, y: 108))
            context.draw(Text(valueText).font(Theme.mono(34, weight: .semibold)).foregroundColor(Theme.text),
                         at: CGPoint(x: 150, y: 184))
            context.draw(Text(unit).font(.system(size: 12)).foregroundColor(Theme.textSecondary),
                         at: CGPoint(x: 150, y: 212))
        }
        .accessibilityElement()
        .accessibilityLabel("Jauge de débit : \(phase) \(valueText) \(unit)")
    }

    private static func angle(_ fraction: Double) -> Double {
        (startAngle + sweep * fraction) * .pi / 180
    }

    private static func point(_ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    /// Arc tracé en segments (le sens horaire de Path.addArc est inversé dans un Canvas).
    private static func arc(from start: Double, to end: Double) -> Path {
        var path = Path()
        let steps = max(2, Int((end - start) * 120))
        for step in 0...steps {
            let fraction = start + (end - start) * Double(step) / Double(steps)
            let p = point(angle(fraction), radius)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private static func markLabel(_ value: Double) -> String {
        if value >= 1000, value.truncatingRemainder(dividingBy: 1000) == 0, value >= 2000 {
            return "\(Int(value / 1000)) G"
        }
        return String(Int(value.rounded()))
    }
}
