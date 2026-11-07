import NetScopeCore
import SwiftUI

/// Note 92 : « Test VoIP simulé » de Speedtest › Réseau local : flux UDP au débit des appels vers
/// le serveur iperf3 choisi (iperf3 installé, lancé seulement sur clic), note MOS du modèle E.
struct SpeedVoiceView: View {
    @ObservedObject var model: SpeedtestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { title; Spacer(minLength: 8); controls }
                VStack(alignment: .leading, spacing: 8) { title; controls }
            }
            if let error = model.voiceError {
                SpeedBanner(text: error, tone: .critical, systemImage: "xmark.octagon")
            }
            if let last = model.voiceTests.first {
                result(last)
            } else {
                Text("Aucun test\u{00A0}: la note MOS estime la qualité des appels sur ce lien avant d’installer des téléphones.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Test VoIP simulé").font(Theme.bodySemibold).foregroundStyle(Theme.text)
            Text("iperf3 en UDP au débit des appels vers \(model.lanHost.isEmpty ? "le serveur choisi" : model.lanHost), sans appel réel")
                .font(Theme.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Codec", selection: $model.voiceCodecName) {
                ForEach(VoIPCodecProfile.all.sorted { FrenchOrder.precedes($0.name, $1.name) }, id: \.name) { codec in
                    Text(codec.name).tag(codec.name)
                }
            }
            .labelsHidden()
            .fixedSize()
            Stepper("\(model.voiceCalls) appel\(model.voiceCalls > 1 ? "s" : "")", value: $model.voiceCalls, in: 1...30)
                .font(Theme.small)
                .fixedSize()
            Button {
                if model.voiceRunning { model.stopVoiceTest() } else { model.startVoiceTest() }
            } label: {
                Label(model.voiceRunning ? "Arrêter" : "Lancer le test VoIP", systemImage: model.voiceRunning ? "stop.fill" : "phone.fill")
            }
            .buttonStyle(.secondary)
            .speedDisabled(!model.voiceRunning && (model.lanHost.trimmingCharacters(in: .whitespaces).isEmpty
                                                    || (!Launcher.isDemo && model.iperfPath == nil)))
        }
    }

    private func result(_ test: VoIPSyntheticTest) -> some View {
        let tone = color(test.score.grade)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(test.score.mosLabel).font(Theme.mono(26, weight: .semibold)).foregroundStyle(tone)
                Text("MOS · \(test.score.grade.label)").font(Theme.small).foregroundStyle(tone)
            }
            .frame(minWidth: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(test.codec) × \(test.calls) · gigue \(SpeedFormat.number(test.jitterMs))\u{00A0}ms · pertes \(SpeedFormat.number(test.lossPercent, digits: 2))\u{00A0}% · R\u{00A0}=\(SpeedFormat.number(test.score.rFactor, digits: 0))")
                    .font(Theme.small).foregroundStyle(Theme.text)
                Text(test.score.grade.advice + " Latence non mesurée par iperf3\u{00A0}: seuls la gigue, les pertes et le codec comptent.")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func color(_ grade: VoIPGrade) -> Color {
        switch grade {
        case .excellent, .good: return Theme.success
        case .fair: return Theme.accent
        case .poor: return Theme.warning
        case .bad: return Theme.critical
        }
    }
}

/// Source des mesures VoIP du rapport (note 92) : appels de la dernière capture et tests simulés.
@MainActor
enum VoIPReportSource {
    static func calls() -> [VoIPCall] {
        VoIPCall.calls(from: ToolStore.shared.capture.findingsReport().rtpStreams)
    }

    static func tests() -> [VoIPSyntheticTest] {
        SpeedtestModel.shared.voiceTests
    }
}
