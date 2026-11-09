import Foundation
import NetScopeCore

/// Testeur HTTP ou API de la Boîte à outils (note 116). La requête reste en mémoire : ni son corps
/// ni ses en-têtes ne sont enregistrés, l'historique ne reçoit que la méthode et l'URL masquée.
@MainActor
final class HTTPTesterModel: ObservableObject {
    static let shared = HTTPTesterModel()

    struct HeaderRow: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    enum ResponseTab: String, CaseIterable, Identifiable {
        case body = "Corps", headers = "En-têtes", timings = "Minutages"
        var id: String { rawValue }
    }

    static let timeouts: [Double] = [5, 10, 15, 30, 60, 120]

    @Published var method: HTTPMethod = .get
    @Published var url = ""
    @Published var headers: [HeaderRow] = []
    @Published var body = ""
    @Published var followRedirects = true
    @Published var acceptsUntrustedCertificate = false
    @Published var timeout: Double = 15
    @Published var showsHeaders = false
    @Published var showsBody = false
    @Published var responseTab: ResponseTab = .body
    /// Vrai : JSON réindenté ; faux : corps tel que reçu.
    @Published var showsFormattedBody = true
    @Published private(set) var isRunning = false
    @Published private(set) var result: HTTPResponseResult?
    @Published var error: String?

    let isDemo = CommandLine.arguments.contains("--demo")
    private var task: Task<Void, Never>?
    private var generation = 0

    private init() {
        if isDemo { HTTPTesterDemo.load(into: self) }
    }

    var spec: HTTPRequestSpec {
        HTTPRequestSpec(method: method, url: url.trimmingCharacters(in: .whitespaces),
                        headers: headers.filter { !$0.name.isEmpty || !$0.value.isEmpty }
                            .map { HTTPHeader(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) },
                        body: body.isEmpty ? nil : body, followRedirects: followRedirects,
                        acceptsUntrustedCertificate: acceptsUntrustedCertificate, timeout: timeout)
    }

    var command: String { HTTPRedaction.commandLine(spec) }

    var headerCount: Int { headers.filter { !$0.name.isEmpty }.count }

    func addHeader() {
        headers.append(HeaderRow())
        showsHeaders = true
    }

    func removeHeader(_ id: UUID) {
        headers.removeAll { $0.id == id }
    }

    func send(store: ToolStore) {
        guard !isRunning else { return }
        let spec = self.spec
        do {
            _ = try spec.validatedURL()
        } catch {
            self.error = error.localizedDescription
            return
        }
        generation += 1
        let run = generation
        error = nil
        isRunning = true
        store.record(command: HTTPRedaction.historyLine(spec))
        let target = HTTPRedaction.maskedURL(spec.url)
        task = Task { [weak self, isDemo] in
            let outcome: Result<HTTPResponseResult, Error>
            if isDemo {
                try? await Task.sleep(nanoseconds: 400_000_000)
                outcome = .success(HTTPTesterDemo.response())
            } else {
                do { outcome = .success(try await HTTPTester.send(spec)) } catch { outcome = .failure(error) }
            }
            guard let self, run == self.generation else { return }
            self.finish(outcome, target: target, store: store)
        }
    }

    private func finish(_ outcome: Result<HTTPResponseResult, Error>, target: String, store: ToolStore) {
        isRunning = false
        switch outcome {
        case .success(let response):
            result = response
            let duration = PingFormat.ms(response.timings.total)
            store.record(ToolRecent(tool: .http, target: target, summary: "\(response.statusCode) \(response.statusText) · \(duration)", status: Self.status(response.statusCode)))
        case .failure(is CancellationError):
            break
        case .failure(let failure):
            result = nil
            error = failure.localizedDescription
            store.record(ToolRecent(tool: .http, target: target, summary: failure.localizedDescription, status: .failure))
        }
    }

    func cancel() {
        guard isRunning else { return }
        generation += 1
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Un 4xx ou un 5xx est une réponse reçue, pas une panne de l'outil.
    private static func status(_ code: Int) -> ToolRecent.Status {
        switch code {
        case 500...: return .failure
        case 400..<500: return .warning
        default: return .ok
        }
    }

    /// Réservé à la démonstration (`HTTPTesterDemo`).
    func loadDemoResult(_ response: HTTPResponseResult) { result = response }
}
