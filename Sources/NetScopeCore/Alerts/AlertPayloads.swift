import Foundation

// Mise en forme d'un lot d'alertes pour chaque canal : courriel (texte et HTML), carte adaptative
// Microsoft Teams (flux Workflows), message en blocs Slack, JSON générique documenté.

/// Contexte commun : nom du Mac qui envoie, version, fuseau et langue des dates.
public struct AlertContext: Sendable {
    public var origin: String
    public var version: String
    public var timeZone: TimeZone

    public init(origin: String, version: String, timeZone: TimeZone = .current) {
        self.origin = AlertText.singleLine(origin)
        self.version = version
        self.timeZone = timeZone
    }

    /// « 4 nov. 2026 à 14:03 ».
    public func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy 'à' HH:mm"
        return formatter.string(from: date)
    }

    /// « 14:03:12 ».
    public func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_CA")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// ISO 8601 (UTC) pour le JSON.
    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public enum AlertComposer {
    /// Au plus ce nombre d'événements détaillés dans un message ; les autres sont comptés.
    public static let maxListed = 10

    // MARK: Courriel

    public static func mail(_ batch: AlertBatch, smtp: AlertSMTPSettings, context: AlertContext, now: Date) -> AlertMailMessage {
        AlertMailMessage(from: smtp.from, fromName: smtp.fromName.isEmpty ? "NetScope" : smtp.fromName,
                         to: smtp.recipients.filter(AlertAddress.isValid), subject: batch.subject,
                         textBody: text(batch, context: context), htmlBody: html(batch, context: context),
                         date: now, encoding: smtp.encoding, mailer: "NetScope \(context.version)")
    }

    /// Corps texte du courriel.
    public static func text(_ batch: AlertBatch, context: AlertContext) -> String {
        var lines: [String] = []
        if batch.events.count == 1, let event = batch.events.first {
            lines.append(event.title)
            lines.append("\(event.severity.label) · \(context.stamp(event.occurredAt)) · \(context.origin)")
            lines.append("")
            lines.append(event.message)
            if !event.details.isEmpty {
                lines.append("")
                for detail in event.details { lines.append("  \(detail.label)\u{00A0}: \(detail.value)") }
            }
        } else {
            lines.append(batch.title + " (\(batch.breakdown))")
            lines.append("\(context.stamp(batch.createdAt)) · \(context.origin)")
            for event in batch.events.prefix(maxListed) {
                lines.append("")
                lines.append("• [\(event.severity.label)] \(event.title) — \(context.clock(event.occurredAt))")
                lines.append("  \(event.message)")
            }
            if batch.events.count > maxListed {
                lines.append("")
                lines.append("… et \(batch.events.count - maxListed) autre(s) événement(s).")
            }
        }
        if batch.suppressedCount > 0 {
            lines.append("")
            lines.append(suppressedLine(batch.suppressedCount))
        }
        lines.append("")
        lines.append("—")
        lines.append("Envoyé par NetScope \(context.version) depuis \(context.origin). Alertes réglées dans Réglages › Alertes.")
        return lines.joined(separator: "\n")
    }

    static func suppressedLine(_ count: Int) -> String {
        "\(count) répétition\(count > 1 ? "s" : "") regroupée\(count > 1 ? "s" : "") par l’anti-rafale depuis la dernière alerte."
    }

    /// Corps HTML (styles en ligne, lisible dans Outlook, Mail et Gmail).
    public static func html(_ batch: AlertBatch, context: AlertContext) -> String {
        func color(_ severity: AlertSeverity) -> String {
            switch severity {
            case .critical: return "#B91C1C"
            case .warning: return "#C2410C"
            case .info: return "#1D4ED8"
            }
        }
        var rows = ""
        for event in batch.events.prefix(maxListed) {
            var details = ""
            for detail in event.details {
                details += "<tr><td style=\"color:#4B5563;padding:2px 12px 2px 0\">\(escape(detail.label))</td>"
                    + "<td style=\"font-family:Menlo,monospace;padding:2px 0\">\(escape(detail.value))</td></tr>"
            }
            rows += """
            <div style="border-left:4px solid \(color(event.severity));padding:8px 12px;margin:12px 0;background:#F9FAFB">\
            <div style="font-size:12px;color:\(color(event.severity));font-weight:600">\(escape(event.severity.label.uppercased())) · \(escape(context.stamp(event.occurredAt)))</div>\
            <div style="font-size:15px;font-weight:700;margin:2px 0">\(escape(event.title))</div>\
            <div style="font-size:13px">\(escape(event.message))</div>\
            \(details.isEmpty ? "" : "<table style=\"font-size:12px;margin-top:6px;border-collapse:collapse\">\(details)</table>")\
            </div>
            """
        }
        let more = batch.events.count > maxListed ? "<p style=\"font-size:12px;color:#4B5563\">… et \(batch.events.count - maxListed) autre(s) événement(s).</p>" : ""
        let suppressed = batch.suppressedCount > 0 ? "<p style=\"font-size:12px;color:#4B5563\">\(escape(suppressedLine(batch.suppressedCount)))</p>" : ""
        let heading = batch.events.count == 1 ? "" : "<h2 style=\"font-size:16px;margin:0 0 4px\">\(escape(batch.title)) (\(escape(batch.breakdown)))</h2>"
        return """
        <!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"></head>\
        <body style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#111827">\
        \(heading)\(rows)\(more)\(suppressed)\
        <p style="font-size:11px;color:#6B7280;margin-top:16px">Envoyé par NetScope \(escape(context.version)) depuis \(escape(context.origin)). Alertes réglées dans Réglages › Alertes.</p>\
        </body></html>
        """
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Microsoft Teams (Workflows, carte adaptative 1.4)

    public static func teams(_ batch: AlertBatch, context: AlertContext) -> [String: Any] {
        func color(_ severity: AlertSeverity) -> String {
            switch severity {
            case .critical: return "Attention"
            case .warning: return "Warning"
            case .info: return "Accent"
            }
        }
        var body: [[String: Any]] = [
            ["type": "TextBlock", "text": batch.title, "size": "Large", "weight": "Bolder", "wrap": true, "color": color(batch.severity)],
            ["type": "TextBlock", "text": batch.events.count == 1
                ? "\(batch.severity.label) · \(context.stamp(batch.events[0].occurredAt)) · \(context.origin)"
                : "\(batch.breakdown) · \(context.stamp(batch.createdAt)) · \(context.origin)",
             "isSubtle": true, "spacing": "None", "wrap": true],
        ]
        if batch.events.count == 1, let event = batch.events.first {
            body.append(["type": "TextBlock", "text": event.message, "wrap": true])
            if !event.details.isEmpty {
                body.append(["type": "FactSet", "facts": event.details.map { ["title": $0.label, "value": $0.value] }])
            }
        } else {
            for event in batch.events.prefix(maxListed) {
                body.append(["type": "Container", "separator": true, "items": [
                    ["type": "TextBlock", "text": "\(event.severity.label) · \(event.title)", "weight": "Bolder", "wrap": true,
                     "color": color(event.severity)],
                    ["type": "TextBlock", "text": "\(context.clock(event.occurredAt)) — \(event.message)", "wrap": true, "spacing": "None"],
                ]])
            }
            if batch.events.count > maxListed {
                body.append(["type": "TextBlock", "text": "… et \(batch.events.count - maxListed) autre(s) événement(s).", "isSubtle": true, "wrap": true])
            }
        }
        if batch.suppressedCount > 0 {
            body.append(["type": "TextBlock", "text": suppressedLine(batch.suppressedCount), "isSubtle": true, "wrap": true, "size": "Small"])
        }
        body.append(["type": "TextBlock", "text": "NetScope \(context.version)", "isSubtle": true, "size": "Small", "spacing": "Medium"])
        let card: [String: Any] = [
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "type": "AdaptiveCard",
            "version": "1.4",
            "msteams": ["width": "Full"],
            "body": body,
        ]
        return [
            "type": "message",
            "attachments": [["contentType": "application/vnd.microsoft.card.adaptive", "contentUrl": NSNull(), "content": card]],
        ]
    }

    // MARK: Slack (incoming webhook, blocs)

    public static func slack(_ batch: AlertBatch, context: AlertContext) -> [String: Any] {
        func emoji(_ severity: AlertSeverity) -> String {
            switch severity {
            case .critical: return ":red_circle:"
            case .warning: return ":large_orange_circle:"
            case .info: return ":large_blue_circle:"
            }
        }
        var blocks: [[String: Any]] = [
            ["type": "header", "text": ["type": "plain_text", "text": String(batch.title.prefix(150)), "emoji": true]],
        ]
        if batch.events.count == 1, let event = batch.events.first {
            var text = "\(emoji(event.severity)) *\(slackEscape(event.severity.label))* · \(slackEscape(event.message))"
            if !event.details.isEmpty {
                text += "\n" + event.details.map { "• \(slackEscape($0.label))\u{00A0}: `\(slackEscape($0.value))`" }.joined(separator: "\n")
            }
            blocks.append(["type": "section", "text": ["type": "mrkdwn", "text": String(text.prefix(3000))]])
        } else {
            for event in batch.events.prefix(maxListed) {
                let text = "\(emoji(event.severity)) *\(slackEscape(event.title))* — \(context.clock(event.occurredAt))\n\(slackEscape(event.message))"
                blocks.append(["type": "section", "text": ["type": "mrkdwn", "text": String(text.prefix(3000))]])
            }
            if batch.events.count > maxListed {
                blocks.append(["type": "section", "text": ["type": "mrkdwn", "text": "… et \(batch.events.count - maxListed) autre(s) événement(s)."]])
            }
        }
        var context_ = "NetScope \(slackEscape(context.version)) · \(slackEscape(context.origin)) · \(context.stamp(batch.createdAt))"
        if batch.suppressedCount > 0 { context_ += " · " + suppressedLine(batch.suppressedCount) }
        blocks.append(["type": "context", "elements": [["type": "mrkdwn", "text": context_]]])
        return ["text": batch.subject, "blocks": blocks]
    }

    /// Échappement Slack (&, <, >) : aucune mention ni lien injecté par un nom d'appareil.
    public static func slackEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: JSON générique (schéma 1)

    /// Format documenté du webhook générique (POST, Content-Type: application/json) :
    ///
    ///     {
    ///       "source": "NetScope", "schema": 1, "version": "0.8.0",
    ///       "test": false, "sentAt": "2026-11-04T19:03:00Z", "origin": "MacBook de Dany",
    ///       "title": "Caméra-Quai hors ligne", "severity": "critical",
    ///       "count": 1, "suppressed": 0,
    ///       "events": [{
    ///         "id": "…UUID…", "kind": "sonde.panne", "severity": "critical",
    ///         "title": "Caméra-Quai hors ligne", "message": "Aucune réponse…",
    ///         "subject": "…", "occurredAt": "2026-11-04T19:02:41Z",
    ///         "details": [{"label": "Cible", "value": "192.168.50.21"}]
    ///       }]
    ///     }
    ///
    /// `kind` : sonde.panne, sonde.alerte, sonde.retablie, appareil.nouveau, dhcp.non-autorise,
    /// service.incident, scan.termine, test. `severity` : info, warning, critical.
    public struct GenericPayload: Codable, Equatable, Sendable {
        public struct Event: Codable, Equatable, Sendable {
            public var id: String
            public var kind: String
            public var severity: String
            public var title: String
            public var message: String
            public var subject: String
            public var occurredAt: String
            public var details: [AlertDetail]
        }

        public var source = "NetScope"
        public var schema = 1
        public var version: String
        public var test: Bool
        public var sentAt: String
        public var origin: String
        public var title: String
        public var severity: String
        public var count: Int
        public var suppressed: Int
        public var events: [Event]
    }

    public static func generic(_ batch: AlertBatch, context: AlertContext, now: Date) -> GenericPayload {
        GenericPayload(
            version: context.version, test: batch.isTest, sentAt: AlertContext.iso(now), origin: context.origin,
            title: batch.title, severity: batch.severity.rawValue, count: batch.events.count, suppressed: batch.suppressedCount,
            events: batch.events.map { event in
                GenericPayload.Event(id: event.id.uuidString.lowercased(), kind: event.kind.rawValue, severity: event.severity.rawValue,
                                     title: event.title, message: event.message, subject: event.subject,
                                     occurredAt: AlertContext.iso(event.occurredAt), details: event.details)
            })
    }

    /// Corps JSON d'un webhook (clés triées : sortie stable).
    public static func body(for kind: AlertWebhookKind, batch: AlertBatch, context: AlertContext, now: Date) throws -> Data {
        switch kind {
        case .teams:
            return try JSONSerialization.data(withJSONObject: teams(batch, context: context), options: [.sortedKeys, .withoutEscapingSlashes])
        case .slack:
            return try JSONSerialization.data(withJSONObject: slack(batch, context: context), options: [.sortedKeys, .withoutEscapingSlashes])
        case .generic:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(generic(batch, context: context, now: now))
        }
    }
}
