import Foundation

// Dossiers nuage : l'écriture va d'abord dans la copie locale, l'envoi réel se fait ensuite. On lit
// l'état de synchronisation du fichier d'essai (attributs « ubiquitous » d'iCloud Drive, exposés
// aussi par les dossiers File Provider qui les renseignent) jusqu'à « envoyé », avec un délai
// maximal. Le suivi est une petite machine à états vérifiable sur des relevés fixes.

/// État d'envoi lu sur le fichier à un instant.
public struct DiskCloudSample: Equatable, Sendable {
    /// Secondes depuis la fin de l'écriture.
    public var time: Double
    /// Le fichier est géré par un service nuage (nil : attribut non fourni).
    public var isUbiquitous: Bool?
    public var isUploading: Bool?
    public var isUploaded: Bool?
    /// Erreur d'envoi signalée par le service.
    public var uploadError: String?

    public init(time: Double, isUbiquitous: Bool?, isUploading: Bool? = nil, isUploaded: Bool? = nil, uploadError: String? = nil) {
        self.time = time
        self.isUbiquitous = isUbiquitous
        self.isUploading = isUploading
        self.isUploaded = isUploaded
        self.uploadError = uploadError
    }

    /// Le service renseigne au moins un attribut d'envoi.
    var reportsState: Bool { isUbiquitous == true || isUploading != nil || isUploaded != nil }
}

/// Bilan du suivi d'envoi.
public enum DiskCloudStatus: String, Codable, Sendable {
    /// Relevés en cours, rien de conclu.
    case attente
    case envoi
    case envoye
    /// Le service ne renseigne pas l'état d'envoi du fichier.
    case nonFourni
    case delaiDepasse
    case erreur
    /// Test arrêté pendant l'envoi.
    case arrete

    public var label: String {
        switch self {
        case .attente: return "En attente du service"
        case .envoi: return "Envoi en cours"
        case .envoye: return "Envoyé"
        case .nonFourni: return "État non fourni"
        case .delaiDepasse: return "Délai dépassé"
        case .erreur: return "Erreur d’envoi"
        case .arrete: return "Arrêté"
        }
    }

    public var isFinal: Bool { self != .attente && self != .envoi }
}

/// Machine à états du suivi d'envoi.
public struct DiskCloudTracker: Sendable {
    /// Sans aucun attribut d'envoi après ce délai, on conclut que le service ne le fournit pas.
    public var grace: Double
    /// Délai maximal d'attente de « envoyé ».
    public var timeout: Double
    public private(set) var status: DiskCloudStatus = .attente
    /// Secondes entre la fin de l'écriture et « envoyé ».
    public private(set) var uploadedAfter: Double?
    public private(set) var firstUploadingAt: Double?
    public private(set) var error: String?
    private var sawState = false
    /// Début de l'erreur d'envoi en cours (nil : pas d'erreur au dernier relevé).
    private var errorSince: Double?
    /// iCloud signale souvent une erreur passagère pendant l'envoi (fichier encore ouvert, file
    /// d'attente, reprise réseau) qui disparaît d'elle-même : on ne conclut « erreur » que si elle
    /// dure au moins ce délai, ou si elle est encore là au délai maximal.
    public var errorPersistence: Double

    public init(grace: Double = 8, timeout: Double = 600, errorPersistence: Double = 45) {
        self.grace = grace
        self.timeout = timeout
        self.errorPersistence = errorPersistence
    }

    /// Ajoute un relevé ; renvoie l'état après ce relevé.
    @discardableResult
    public mutating func add(_ sample: DiskCloudSample) -> DiskCloudStatus {
        guard !status.isFinal else { return status }
        if sample.reportsState { sawState = true }
        if sample.isUploaded == true {
            uploadedAfter = sample.time
            status = .envoye
            return status
        }
        if let message = sample.uploadError, !message.isEmpty {
            error = message
            if errorSince == nil { errorSince = sample.time }
            if sample.time - (errorSince ?? sample.time) >= errorPersistence || sample.time >= timeout {
                status = .erreur
                return status
            }
            return status
        }
        errorSince = nil
        if sample.isUploaded == true {
            uploadedAfter = sample.time
            status = .envoye
            return status
        }
        if sample.isUploading == true {
            if firstUploadingAt == nil { firstUploadingAt = sample.time }
            status = .envoi
        }
        if !sawState && sample.time >= grace {
            status = .nonFourni
            return status
        }
        if sample.time >= timeout {
            status = .delaiDepasse
        }
        return status
    }

    /// En dessous (une seconde, plus que l'intervalle des relevés), l'envoi n'est pas mesurable.
    public static let minimumUploadSeconds = 1.0

    public mutating func stop() {
        if !status.isFinal { status = .arrete }
    }

    /// Débit effectif d'envoi (Mbit/s) : `bytes` envoyés en `seconds`, comptées depuis la fin de
    /// l'écriture (l'envoi a pu commencer avant : le débit réel est au moins celui-là). Sous
    /// `minimumUploadSeconds`, le fichier est parti pendant l'écriture : aucun débit mesurable.
    public static func uploadMbps(bytes: Int64, seconds: Double?) -> Double? {
        guard let seconds, seconds >= minimumUploadSeconds else { return nil }
        return Double(bytes) * 8 / 1_000_000 / seconds
    }
}

/// Lecture des attributs d'envoi d'un fichier (URLResourceValues).
public enum DiskCloudReader {
    public static func sample(_ url: URL, time: Double) -> DiskCloudSample {
        var url = url
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey,
                                         .ubiquitousItemUploadingErrorKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return DiskCloudSample(time: time, isUbiquitous: nil)
        }
        return DiskCloudSample(time: time, isUbiquitous: values.isUbiquitousItem, isUploading: values.ubiquitousItemIsUploading,
                               isUploaded: values.ubiquitousItemIsUploaded,
                               uploadError: values.ubiquitousItemUploadingError.map(describe))
    }

    /// Message d'iCloud avec son domaine et son code (« … (NSCocoaErrorDomain 4355) »), pour le diagnostic.
    static func describe(_ error: NSError) -> String {
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ; \($0.domain) \($0.code)" } ?? ""
        return "\(error.localizedDescription) (\(error.domain) \(error.code)\(underlying))"
    }
}
