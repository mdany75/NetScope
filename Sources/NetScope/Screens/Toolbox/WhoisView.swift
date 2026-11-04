import NetScopeCore
import SwiftUI

@MainActor
final class ToolWhoisModel: ObservableObject {
    @Published var target = "8.8.8.8"
    @Published private(set) var isRunning = false
    @Published private(set) var result: WhoisResult?
    @Published var error: String?

    func run(store: ToolStore) {
        let text = target.trimmingCharacters(in: .whitespaces)
        do {
            _ = try Whois.validate(text)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
            return
        }
        error = nil
        isRunning = true
        store.record(command: "whois \(text)")
        Task {
            do {
                let result = try await Whois.query(text)
                self.result = result
                let summary = result.fields.prefix(3).map(\.value).joined(separator: " · ")
                store.record(ToolRecent(tool: .whois, target: text, summary: summary.isEmpty ? "Réponse sans champ reconnu" : summary, status: .ok))
            } catch {
                self.result = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                store.record(ToolRecent(tool: .whois, target: text, summary: self.error ?? "Échec", status: .failure))
            }
            self.isRunning = false
        }
    }
}

/// Whois d'une adresse, d'un ASN ou d'un domaine, par /usr/bin/whois.
struct WhoisView: View {
    @ObservedObject var model: ToolWhoisModel
    @ObservedObject var store: ToolStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                ToolLabeledField(label: "Adresse IP, ASN ou domaine") {
                    ToolTextField(placeholder: "8.8.8.8, AS15169, exemple.ca", text: $model.target) { model.run(store: store) }
                }
                Button(model.isRunning ? "Interrogation…" : "Interroger") { model.run(store: store) }
                    .buttonStyle(.primary)
                    .disabled(model.isRunning || !Whois.isAvailable)
            }
            if !Whois.isAvailable {
                ToolNotice(tone: .warning, message: "La commande /usr/bin/whois est introuvable sur ce Mac.")
            }
            if let error = model.error {
                ToolNotice(tone: .critical, message: error)
            }
            if let result = model.result {
                if !result.fields.isEmpty {
                    ToolCellGrid(cells: result.fields.prefix(9).map { ToolCell(key: $0.key, value: $0.value) }, columns: 3, valueSize: 13)
                }
                ScrollView {
                    Text(result.raw.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.consoleText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(minHeight: 160, maxHeight: 340)
                .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.console))
                HStack {
                    Text("Réponse en \(ToolFormat.milliseconds(result.durationMs)) · \(result.raw.split(separator: "\n").count) lignes")
                        .font(Theme.small).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Copier la réponse") { ToolActions.copy(result.raw) }.buttonStyle(.ghost)
                }
            } else if model.error == nil {
                Text("La requête part du Mac vers les serveurs Whois publics (IANA, puis le registre régional ou le bureau d’enregistrement).")
                    .font(Theme.small).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
