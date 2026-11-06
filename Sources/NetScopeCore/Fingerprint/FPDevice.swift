import Foundation

extension Device {
    /// Note 68 : empreinte de l'appareil (système, versions, services en clair), d'après ses indices,
    /// ses ports ouverts et son fabricant. Calculée à la demande (règles pures, rapides).
    public var fingerprintReport: FPReport {
        Fingerprinter.analyze(fingerprint, openPorts: openPorts, vendor: vendor)
    }

    /// Ajoute les services lus par un scan de ports (bannières, HTTP, TLS, SMB).
    public mutating func recordServices(_ results: [PortScanResult]) {
        let observations = results.compactMap(\.observation).filter { !$0.isEmpty }
        guard !observations.isEmpty else { return }
        var evidence = fingerprint ?? FPEvidence()
        for observation in observations { evidence.record(observation) }
        fingerprint = evidence
    }

    /// Ajoute sysDescr (et sysObjectID) lus par la découverte SNMP.
    public mutating func recordSysDescr(_ descr: String, objectID: String?) {
        let text = descr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var evidence = fingerprint ?? FPEvidence()
        evidence.sysDescr = text
        evidence.sysObjectID = objectID ?? evidence.sysObjectID
        fingerprint = evidence
    }
}
