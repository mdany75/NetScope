import NetScopeCore
import SwiftUI

// Note 68 : ce que les outils déjà lancés par l'utilisateur ont lu (scan de ports avec détection
// de services, sonde web de la fiche, découverte SNMP du scan) rejoint l'empreinte de l'appareil.
// Aucun envoi ici : seulement l'enregistrement de réponses déjà reçues.

extension AppState {
    /// Services lus par un scan de ports sur `host` (IP ou nom d'un appareil du Scanner).
    func recordServices(host: String, results: [PortScanResult]) {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard results.contains(where: { $0.observation != nil }),
              var device = devices.first(where: { $0.ip.description == target || $0.hostname == target }) else { return }
        let before = device.fingerprint
        device.recordServices(results)
        guard device.fingerprint != before else { return }
        let guessed = ScanDeviceClassifier.guess(device)
        if guessed != .inconnu { device.deviceType = guessed }
        merge([device])
    }

    /// Réponse de la sonde web de la fiche (Server, titre, certificat).
    func recordWebProbe(_ result: HTTPProbeResult) {
        guard let host = result.url.host else { return }
        let tls = result.url.scheme?.lowercased() == "https"
        let port = UInt16(clamping: result.url.port ?? (tls ? 443 : 80))
        var observation = FPServiceObservation(port: port, httpStatus: "HTTP \(result.statusCode)", httpServer: result.server,
                                               httpTitle: result.title, tls: tls, observedAt: Date())
        if let certificate = result.certificate, !certificate.subject.isEmpty {
            observation.certSubject = FPCertName(commonName: certificate.subject)
            observation.certSelfSigned = certificate.isSelfSigned
            observation.certNotAfter = certificate.validUntil
        }
        recordServices(host: host, results: [PortScanResult(port: port, state: .open, observation: observation)])
    }

    /// sysDescr des agents SNMP trouvés par la découverte du scan.
    func recordSysDescr(_ found: [SNMPDiscovered]) {
        var changed: [Device] = []
        for item in found {
            guard var device = device(withID: item.host.description) else { continue }
            let before = device.fingerprint
            device.recordSysDescr(item.sysDescr, objectID: item.sysObjectID)
            if device.fingerprint != before {
                let guessed = ScanDeviceClassifier.guess(device)
                if guessed != .inconnu { device.deviceType = guessed }
                changed.append(device)
            }
        }
        if !changed.isEmpty { merge(changed) }
    }
}
