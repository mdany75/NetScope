import CommonCrypto
import Foundation
import Security

// Confiance dans le certificat de la FortiGate, souvent autosigné : par son empreinte SHA-256,
// acceptée une fois par l'utilisateur. Jamais d'acceptation silencieuse d'un certificat inconnu,
// et refus si l'empreinte change.

public enum FortiTrustDecision: Equatable, Sendable {
    case accept
    /// Premier contact : aucune empreinte acceptée.
    case unknown(presented: String)
    /// Empreinte différente de celle qui a été acceptée.
    case changed(expected: String, presented: String)
}

public enum FortiCertificatePin {
    /// Empreinte SHA-256 du certificat (DER), en hexadécimal majuscule séparé par « : ».
    public static func fingerprint(der: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        der.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(der.count), &digest) }
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Forme comparable : chiffres hexadécimaux seuls, en majuscules (espaces, « : » et casse ignorés).
    public static func normalize(_ text: String) -> String {
        text.uppercased().filter { $0.isHexDigit }
    }

    /// Empreinte saisie ou collée valide (64 chiffres hexadécimaux).
    public static func isValid(_ text: String) -> Bool { normalize(text).count == 64 }

    /// Forme affichée « AB:CD:… » d'une empreinte saisie.
    public static func display(_ text: String) -> String {
        let hex = Array(normalize(text))
        return stride(from: 0, to: hex.count, by: 2).map { String(hex[$0..<min($0 + 2, hex.count)]) }.joined(separator: ":")
    }

    /// Décision pour l'empreinte présentée par le serveur.
    public static func evaluate(presented: String, pinned: String?) -> FortiTrustDecision {
        guard let pinned, !normalize(pinned).isEmpty else { return .unknown(presented: display(presented)) }
        return normalize(pinned) == normalize(presented) ? .accept : .changed(expected: display(pinned), presented: display(presented))
    }
}

/// Délégué de session : vérifie le certificat par son empreinte, refuse toute redirection (le
/// jeton ne doit jamais partir ailleurs) et note pourquoi un certificat a été refusé.
final class FortiSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let pinned: String?
    private let lock = NSLock()
    private var _rejection: FortiGateError?

    init(pinned: String?) {
        self.pinned = pinned
    }

    var rejection: FortiGateError? {
        lock.lock()
        defer { lock.unlock() }
        return _rejection
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            // Aucune autre authentification (certificat client, mot de passe) n'est fournie.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let presented = FortiCertificatePin.fingerprint(der: der)
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        switch FortiCertificatePin.evaluate(presented: presented, pinned: pinned) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .unknown(let fp):
            record(.certificateUnknown(fingerprint: fp, subject: subject))
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .changed(let expected, let fp):
            record(.certificateChanged(expected: expected, presented: fp))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func record(_ error: FortiGateError) {
        lock.lock()
        _rejection = error
        lock.unlock()
    }
}
