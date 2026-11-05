import Foundation

// Note 78 : envoi automatique d'un rapport planifié par le serveur SMTP déjà configuré dans
// Réglages › Alertes (même serveur, même expéditeur, mot de passe lu au Trousseau). Désactivé par
// défaut : il faut choisir « Envoyer par courriel » pour CE rapport planifié et donner les
// destinataires de chaque site. « Envoyer un essai » le vérifie à la main. Ce fichier compose le
// message et vérifie les réglages ; l'envoi lui-même passe par SMTPSubmission (jamais dans les
// tests ni en démonstration).

public enum ReportMail {
    /// Taille au-delà de laquelle beaucoup de serveurs refusent un message (pièce jointe en base64 comprise).
    public static let maxAttachmentBytes = 15 * 1_024 * 1_024

    /// Destinataires valides d'un site, sans doublon.
    public static func recipients(_ schedule: ReportSchedule, siteKey: String) -> [String] {
        var seen = Set<String>()
        return (schedule.mailRecipients[siteKey] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { AlertAddress.isValid($0) && seen.insert($0.lowercased()).inserted }
    }

    /// Problèmes qui empêchent l'envoi pour ce site (vide : prêt). Réglages SMTP des Alertes, sans
    /// leurs destinataires : ce sont ceux du rapport qui comptent.
    public static func problems(smtp: AlertSMTPSettings, hasPassword: Bool, schedule: ReportSchedule, siteKey: String,
                                siteName: String) -> [String] {
        var settings = smtp
        settings.recipients = ["rapport@exemple.ca"]
        var list = settings.problems(hasPassword: hasPassword).map { "Réglages › Alertes\u{00A0}: " + $0 }
        let raw = (schedule.mailRecipients[siteKey] ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let bad = raw.first(where: { !AlertAddress.isValid($0) }) {
            list.append("Destinataire invalide pour \(siteName)\u{00A0}: «\u{00A0}\(bad)\u{00A0}».")
        }
        if recipients(schedule, siteKey: siteKey).isEmpty {
            list.append("Aucun destinataire pour \(siteName).")
        }
        return list
    }

    /// Message du rapport, pièce jointe comprise. `isTest` : « Envoyer un essai » (objet préfixé).
    public static func message(scheduleName: String, siteName: String, fileName: String, data: Data, recipients: [String],
                               smtp: AlertSMTPSettings, date: Date, isTest: Bool = false, mailer: String = "NetScope",
                               calendar: Calendar = .current) -> AlertMailMessage {
        let day = ReportText.longDate(ReportText.isoDay(date, calendar: calendar)) ?? ReportText.isoDay(date, calendar: calendar)
        let subject = (isTest ? "[Essai] " : "") + scheduleName + " — " + siteName + " — " + day
        var text = "Bonjour,\n\n"
        text += "Vous trouverez ci-joint le rapport «\u{00A0}\(scheduleName)\u{00A0}» du site \(siteName), produit le \(day).\n\n"
        if isTest {
            text += "Ceci est un essai envoyé à la main depuis NetScope pour vérifier l’envoi de ce rapport planifié.\n\n"
        }
        text += "Pièce jointe\u{00A0}: \(fileName) (\(sizeLabel(data.count))).\n\n"
        text += "Message automatique de NetScope (\(mailer)), envoyé par \(smtp.host.trimmingCharacters(in: .whitespaces)). Ne pas répondre.\n"
        var message = AlertMailMessage(from: smtp.from, fromName: smtp.fromName, to: recipients, subject: subject, textBody: text,
                                       date: date, encoding: smtp.encoding, mailer: mailer)
        let ext = (fileName as NSString).pathExtension
        message.attachments = [AlertMailAttachment(fileName: fileName, contentType: AlertMailAttachment.contentType(forExtension: ext),
                                                   data: data)]
        return message
    }

    /// « 182 ko », « 1,4 Mo ».
    public static func sizeLabel(_ bytes: Int) -> String {
        if bytes < 1_024 * 1_024 { return "\(max(1, (bytes + 512) / 1_024))\u{00A0}ko" }
        return ToolFormat.decimal(Double(bytes) / 1_048_576) + "\u{00A0}Mo"
    }

    /// Résumé d'un envoi pour la liste des rapports planifiés (« envoyé à 2 destinataires »).
    public static func sentSummary(accepted: Int, rejected: [String]) -> String {
        var text = "envoyé à \(accepted) destinataire" + (accepted > 1 ? "s" : "")
        if !rejected.isEmpty { text += " (refusé\u{00A0}: " + rejected.joined(separator: ", ") + ")" }
        return text
    }
}
