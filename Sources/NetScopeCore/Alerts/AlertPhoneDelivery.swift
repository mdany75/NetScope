import Foundation

// Note 76 (0.28.0) : envoi d'un lot sur ntfy ou Pushover par le client HTTP injectable
// d'AlertDelivery (faux client dans les tests : aucun envoi réel). Le journal ne contient jamais
// de secret : jeton ntfy, jeton d'application et clé utilisateur Pushover passent par AlertRedactor.

extension AlertDelivery {
    func deliverNtfy(_ batch: AlertBatch, settings: AlertSettings, secrets: AlertSecrets, now: Date) async -> AlertLogEntry {
        let name = settings.channelName(.ntfy)
        let problems = settings.ntfy.problems()
        guard problems.isEmpty else {
            return entry(batch, kind: "ntfy", name: name, outcome: .failed, detail: problems.joined(separator: " "), now: now, secrets: secrets)
        }
        let started = Date()
        do {
            let request = try AlertNtfyRequest.make(batch, settings: settings.ntfy, token: secrets.ntfyToken, context: context)
            let response = try await post(request, service: "ntfy")
            let duration = Date().timeIntervalSince(started) * 1000
            guard (200..<300).contains(response.status) else {
                throw AlertPhoneError.http(service: "ntfy", status: response.status, message: AlertNtfyRequest.errorMessage(response.body))
            }
            var detail = "HTTP \(response.status)"
            if let id = AlertNtfyRequest.messageID(response.body) { detail += " · message \(id)" }
            detail += " · priorité \(AlertNtfyRequest.payload(batch, settings: settings.ntfy, context: context).priority)"
            return entry(batch, kind: "ntfy", name: name, outcome: .sent, detail: detail, duration: duration, now: now, secrets: secrets)
        } catch {
            return failure(batch, kind: "ntfy", name: name, error: error, started: started, now: now, secrets: secrets)
        }
    }

    func deliverPushover(_ batch: AlertBatch, settings: AlertSettings, secrets: AlertSecrets, now: Date) async -> AlertLogEntry {
        let name = settings.channelName(.pushover)
        let problems = settings.pushover.problems(hasToken: !(secrets.pushoverToken ?? "").isEmpty,
                                                  hasUserKey: !(secrets.pushoverUser ?? "").isEmpty)
        guard problems.isEmpty else {
            return entry(batch, kind: "pushover", name: name, outcome: .failed, detail: problems.joined(separator: " "), now: now, secrets: secrets)
        }
        let started = Date()
        do {
            let request = try AlertPushoverRequest.make(batch, settings: settings.pushover, token: secrets.pushoverToken,
                                                        userKey: secrets.pushoverUser, context: context)
            let response = try await post(request, service: "Pushover")
            let duration = Date().timeIntervalSince(started) * 1000
            let parsed = AlertPushoverRequest.parse(response.body)
            guard (200..<300).contains(response.status), parsed.ok else {
                let message = parsed.errors.isEmpty
                    ? String(AlertText.singleLine(String(decoding: response.body.prefix(300), as: UTF8.self)).prefix(120))
                    : parsed.errors.joined(separator: " ; ")
                throw AlertPhoneError.http(service: "Pushover", status: response.status, message: message)
            }
            let priority = batch.isTest ? 0 : settings.pushover.priorities.value(for: batch.severity)
            var detail = "HTTP \(response.status) · priorité \(priority)"
            if let request = parsed.request { detail += " · demande \(request)" }
            return entry(batch, kind: "pushover", name: name, outcome: .sent, detail: detail, duration: duration, now: now, secrets: secrets)
        } catch {
            return failure(batch, kind: "pushover", name: name, error: error, started: started, now: now, secrets: secrets)
        }
    }

    private func post(_ request: AlertHTTPRequest, service: String) async throws -> (status: Int, body: Data) {
        do {
            return try await http.post(url: request.url, headers: request.headers, body: request.body, timeout: timeout)
        } catch {
            throw AlertPhoneError.from(error, service: service)
        }
    }

    private func failure(_ batch: AlertBatch, kind: String, name: String, error: Error, started: Date, now: Date,
                         secrets: AlertSecrets) -> AlertLogEntry {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return entry(batch, kind: kind, name: name, outcome: .failed, detail: detail,
                     duration: Date().timeIntervalSince(started) * 1000, now: now, secrets: secrets)
    }
}
