import Foundation
import NetScopeCore

/// Testeur HTTP en démonstration (note 116) : réponse fixe, aucune requête envoyée.
/// Captures : NETSCOPE_OUTIL_DEMO=http ouvre l'outil ; NETSCOPE_HTTP_DEMO=requete (sections
/// dépliées), entetes, minutages, erreur (réponse 500), retenue (307 non suivie, connexion
/// directe) ou vide (avant tout envoi).
@MainActor
enum HTTPTesterDemo {
    static func load(into model: HTTPTesterModel) {
        model.method = .post
        model.url = "https://api.exemple.ca/v2/equipements?site=rimouski&token=FICTIF-0000"
        model.headers = [
            .init(name: "Accept", value: "application/json"),
            .init(name: "Authorization", value: "Bearer FICTIF-JETON-DEMO"),
        ]
        model.body = "{\n  \"nom\": \"SW-ETG2-01\",\n  \"vlan\": 20\n}"
        let variant = ProcessInfo.processInfo.environment["NETSCOPE_HTTP_DEMO"]
        switch variant {
        case "requete":
            model.showsHeaders = true
            model.showsBody = true
        case "entetes": model.responseTab = .headers
        case "minutages", "retenue": model.responseTab = .timings
        default: break
        }
        guard variant != "vide" else { return }
        switch variant {
        case "erreur": model.loadDemoResult(serverError())
        case "retenue": model.loadDemoResult(withheldRedirect())
        default: model.loadDemoResult(response())
        }
    }

    static func response() -> HTTPResponseResult {
        let body = #"{"id":4182,"nom":"SW-ETG2-01","vlan":20,"site":{"code":"rimouski","etages":[1,2,3]},"ports":[{"numero":1,"etat":"actif","poe":true},{"numero":2,"etat":"inactif","poe":false}],"notes":[],"maj":"2026-11-08T09:42:07-05:00"}"#
        let headers = [
            HTTPHeader(name: "Cache-Control", value: "no-store"),
            HTTPHeader(name: "Content-Length", value: "\(body.utf8.count)"),
            HTTPHeader(name: "Content-Type", value: "application/json; charset=utf-8"),
            HTTPHeader(name: "Date", value: "Sun, 08 Nov 2026 14:42:07 GMT"),
            HTTPHeader(name: "Location", value: "/v2/equipements/4182"),
            HTTPHeader(name: "Server", value: "nginx"),
            HTTPHeader(name: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains"),
            HTTPHeader(name: "X-Request-Id", value: "demo-7f3a-42c1"),
        ]
        return HTTPResponseResult(statusCode: 201, version: "HTTP/2", headers: headers, bodyPreview: Data(body.utf8), bodySize: body.utf8.count,
                                  redirects: [HTTPRedirectHop(statusCode: 308, target: "https://api.exemple.ca/v2/equipements/?site=rimouski&token=FICTIF-0000")],
                                  timings: HTTPTimings(dns: 3.4, connect: 11.8, tls: 38.2, firstByte: 142.6, total: 168.9),
                                  remoteAddress: "10.182.10.40:443", finalURL: URL(string: "https://api.exemple.ca/v2/equipements/?site=rimouski&token=FICTIF-0000")!)
    }

    private static func withheldRedirect() -> HTTPResponseResult {
        HTTPResponseResult(statusCode: 307, version: "HTTP/1.1",
                           headers: [HTTPHeader(name: "Location", value: "http://autre.exemple.ca/login")],
                           bodyPreview: Data(), bodySize: 0, unfollowedRedirect: "http://autre.exemple.ca/login",
                           timings: HTTPTimings(connect: 62.4, firstByte: 118.7, total: 119.2, connectIncludesDNS: true),
                           remoteAddress: "api.exemple.ca:80", finalURL: URL(string: "http://api.exemple.ca/login")!)
    }

    private static func serverError() -> HTTPResponseResult {
        let body = "<html><body><h1>500 Internal Server Error</h1><p>Le service d’inventaire ne répond pas (exemple fictif).</p></body></html>"
        return HTTPResponseResult(statusCode: 500, version: "HTTP/1.1",
                                  headers: [HTTPHeader(name: "Content-Type", value: "text/html"), HTTPHeader(name: "Server", value: "nginx")],
                                  bodyPreview: Data(body.utf8), bodySize: body.utf8.count,
                                  timings: HTTPTimings(connect: 2.1, firstByte: 804.3, total: 805.0),
                                  remoteAddress: "10.182.122.1:80", finalURL: URL(string: "http://10.182.122.1/api/etat")!)
    }
}
