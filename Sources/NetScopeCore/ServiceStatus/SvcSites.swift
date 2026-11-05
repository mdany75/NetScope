import Foundation

// Note 53 : services suivis ou non selon le site. Les réseaux sociaux, par exemple, sont masqués
// là où la FortiGate les bloque exprès, et restent suivis ailleurs. Le catalogue garde son choix
// global (« suivi » ou non) ; chaque site peut en plus masquer des catégories entières ou des
// services précis. Rien de secret : enregistré avec le catalogue (services-en-ligne.json).

/// Services et catégories masqués pour un site.
public struct SvcSiteSelection: Codable, Hashable, Sendable {
    /// Catégories masquées (« Réseaux sociaux »).
    public var hiddenCategories: Set<String>
    /// Services masqués un à un (identifiants du catalogue).
    public var hiddenServices: Set<String>

    public init(hiddenCategories: Set<String> = [], hiddenServices: Set<String> = []) {
        self.hiddenCategories = hiddenCategories
        self.hiddenServices = hiddenServices
    }

    public var isEmpty: Bool { hiddenCategories.isEmpty && hiddenServices.isEmpty }

    public func isVisible(_ service: SvcService) -> Bool {
        !hiddenCategories.contains(service.category) && !hiddenServices.contains(service.id)
    }

    /// Montre ou masque une catégorie entière (ses services masqués un à un redeviennent visibles).
    public mutating func setCategory(_ category: String, visible: Bool, in services: [SvcService]) {
        if visible {
            hiddenCategories.remove(category)
        } else {
            hiddenCategories.insert(category)
        }
        let members = Set(services.filter { $0.category == category }.map(\.id))
        hiddenServices.subtract(members)
    }

    /// Montre ou masque un service. Montrer un service d'une catégorie masquée rend la catégorie
    /// visible et masque à la place ses autres services, un à un.
    public mutating func setService(_ service: SvcService, visible: Bool, in services: [SvcService]) {
        if visible {
            hiddenServices.remove(service.id)
            if hiddenCategories.contains(service.category) {
                hiddenCategories.remove(service.category)
                for other in services where other.category == service.category && other.id != service.id {
                    hiddenServices.insert(other.id)
                }
            }
        } else {
            hiddenServices.insert(service.id)
            // Tous les services de la catégorie masqués un à un : la catégorie entière l'est.
            let members = services.filter { $0.category == service.category }
            if !members.isEmpty, members.allSatisfy({ hiddenServices.contains($0.id) }) {
                hiddenCategories.insert(service.category)
                hiddenServices.subtract(members.map(\.id))
            }
        }
    }

    /// État d'une catégorie pour une case à cocher : tout visible, rien, ou en partie.
    public func categoryState(_ category: String, in services: [SvcService]) -> SvcCategoryState {
        if hiddenCategories.contains(category) { return .hidden }
        let members = services.filter { $0.category == category }
        let hidden = members.filter { hiddenServices.contains($0.id) }.count
        if hidden == 0 { return .visible }
        return hidden == members.count ? .hidden : .partial
    }
}

/// État d'une catégorie pour un site.
public enum SvcCategoryState: String, Sendable {
    case visible, partial, hidden
}

/// Choix de tous les sites, par clé de site (`SiteFiles.key`).
public struct SvcSitePreferences: Codable, Hashable, Sendable {
    public var bySite: [String: SvcSiteSelection]

    public init(bySite: [String: SvcSiteSelection] = [:]) {
        self.bySite = bySite
    }

    public func selection(for siteKey: String) -> SvcSiteSelection {
        bySite[siteKey] ?? SvcSiteSelection()
    }

    public mutating func update(_ siteKey: String, _ change: (inout SvcSiteSelection) -> Void) {
        var selection = selection(for: siteKey)
        change(&selection)
        bySite[siteKey] = selection.isEmpty ? nil : selection
    }

    /// Services à vérifier sur ce site : suivis dans le catalogue et non masqués pour le site.
    public func visible(_ services: [SvcService], siteKey: String) -> [SvcService] {
        let selection = selection(for: siteKey)
        return services.filter { $0.isEnabled && selection.isVisible($0) }
    }

    /// Oublie un service retiré du catalogue.
    public mutating func forget(serviceID: String) {
        for key in Array(bySite.keys) {
            bySite[key]?.hiddenServices.remove(serviceID)
            if bySite[key]?.isEmpty == true { bySite[key] = nil }
        }
    }
}
