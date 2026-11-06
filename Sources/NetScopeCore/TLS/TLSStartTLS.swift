import Foundation

// Note 70 : partie en clair avant le chiffrement (STARTTLS) pour SMTP, IMAP et POP3. Machine à
// états pure, testée sur des échanges recopiés ; la lecture des réponses SMTP réutilise celle du
// diagnostic SMTP (SMTPReplyParser, SMTPCommand, SMTPExtension). Aucune authentification ni
// commande au-delà de STARTTLS n'est envoyée.

public struct TLSStartTLSDialogue: Sendable {
    public enum Action: Equatable, Sendable {
        /// Ligne à envoyer (sans CRLF).
        case send(String)
        /// Le serveur accepte : démarrer la poignée TLS.
        case startTLS
        /// Échec, avec la raison.
        case fail(String)
    }

    private enum Phase: Sendable { case greeting, capabilities, startTLS, done }

    public let mode: TLSStartMode
    private let ehloName: String
    private var phase = Phase.greeting
    private var smtp = SMTPReplyParser()
    private var buffer: [UInt8] = []
    /// Lignes reçues et envoyées, pour la trace (« S: 220 … », « C: STARTTLS »).
    public private(set) var transcript: [String] = []

    public init(mode: TLSStartMode, ehloName: String = "[127.0.0.1]") {
        self.mode = mode
        self.ehloName = ehloName
    }

    public var isFinished: Bool { phase == .done }

    /// Octets reçus du serveur ; renvoie les actions dans l'ordre (rien de plus après startTLS ou fail).
    public mutating func feed(_ bytes: [UInt8]) -> [Action] {
        guard phase != .done else { return [] }
        var actions: [Action] = []
        switch mode {
        case .direct:
            phase = .done
            return [.startTLS]
        case .smtp:
            let replies: [SMTPReply]
            do {
                replies = try smtp.feed(bytes)
            } catch {
                phase = .done
                return [.fail("Réponse SMTP illisible")]
            }
            for reply in replies where phase != .done {
                transcript += reply.rawLines.map { "S: \($0)" }
                actions += smtpStep(reply)
            }
        case .imap, .pop3:
            buffer += bytes
            while phase != .done, let newline = buffer.firstIndex(of: 0x0A) {
                var lineBytes = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if lineBytes.last == 0x0D { lineBytes.removeLast() }
                let line = String(decoding: lineBytes, as: UTF8.self)
                transcript.append("S: \(line)")
                actions += mode == .imap ? imapStep(line) : pop3Step(line)
            }
            if buffer.count > 16_384 {
                phase = .done
                actions.append(.fail("Réponse trop longue"))
            }
        }
        for case let .send(line) in actions { transcript.append("C: \(line)") }
        return actions
    }

    private mutating func smtpStep(_ reply: SMTPReply) -> [Action] {
        switch phase {
        case .greeting:
            guard reply.code == 220 else { return finish("Bannière refusée\u{00A0}: \(reply.code) \(reply.firstLine)") }
            phase = .capabilities
            return [.send(SMTPCommand.ehlo(ehloName).line)]
        case .capabilities:
            guard reply.code == 250 else { return finish("EHLO refusé\u{00A0}: \(reply.code) \(reply.firstLine)") }
            guard SMTPExtension.parse(ehlo: reply).contains(where: { $0.keyword == "STARTTLS" }) else {
                return finish("Le serveur ne propose pas STARTTLS")
            }
            phase = .startTLS
            return [.send(SMTPCommand.startTLS.line)]
        case .startTLS:
            guard reply.code == 220 else { return finish("STARTTLS refusé\u{00A0}: \(reply.code) \(reply.firstLine)") }
            phase = .done
            return [.startTLS]
        case .done:
            return []
        }
    }

    private mutating func imapStep(_ line: String) -> [Action] {
        let upper = line.uppercased()
        switch phase {
        case .greeting:
            if upper.hasPrefix("* OK") {
                phase = .startTLS
                return [.send("a1 STARTTLS")]
            }
            if upper.hasPrefix("* PREAUTH") { return finish("Session déjà ouverte (PREAUTH)\u{00A0}: STARTTLS impossible") }
            return finish("Accueil IMAP refusé\u{00A0}: \(line)")
        case .startTLS:
            if upper.hasPrefix("* ") { return [] } // réponse non étiquetée (CAPABILITY…)
            if upper.hasPrefix("A1 OK") {
                phase = .done
                return [.startTLS]
            }
            if upper.hasPrefix("A1 ") { return finish("STARTTLS refusé\u{00A0}: \(line)") }
            return []
        case .capabilities, .done:
            return []
        }
    }

    private mutating func pop3Step(_ line: String) -> [Action] {
        switch phase {
        case .greeting:
            guard line.hasPrefix("+OK") else { return finish("Accueil POP3 refusé\u{00A0}: \(line)") }
            phase = .startTLS
            return [.send("STLS")]
        case .startTLS:
            guard line.hasPrefix("+OK") else { return finish("STLS refusé\u{00A0}: \(line)") }
            phase = .done
            return [.startTLS]
        case .capabilities, .done:
            return []
        }
    }

    private mutating func finish(_ reason: String) -> [Action] {
        phase = .done
        return [.fail(reason)]
    }
}
