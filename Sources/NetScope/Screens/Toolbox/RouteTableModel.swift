import Foundation
import NetScopeCore

/// Table de routage de la Boîte à outils (note 119) : lecture locale seulement, rien n'est envoyé
/// ni modifié.
@MainActor
final class RouteTableModel: ObservableObject {
    static let shared = RouteTableModel()

    @Published private(set) var entries: [RouteEntry] = []
    @Published private(set) var isReading = false
    @Published private(set) var readDate: Date?
    @Published private(set) var error: String?
    /// nil : les deux familles.
    @Published var family: RouteFamily?
    @Published var query = ""

    /// Démonstration ou capture : table fictive, jamais celle de ce Mac.
    private let isDemo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--snapshot")

    private init() {
        if ProcessInfo.processInfo.environment["NETSCOPE_ROUTES_DEMO"] == "echec" {
            error = "Lecture impossible\u{00A0}: la commande netstat n’a pas répondu."
        } else if isDemo {
            entries = RouteTable.parse(netstat: RoutesDemo.netstat)
            readDate = Date()
        }
    }

    func readIfNeeded() {
        if readDate == nil { read() }
    }

    func read() {
        guard !isReading, !isDemo else { return }
        isReading = true
        Task { [weak self] in
            let result = await Task.detached { RouteTable.readLocal() }.value
            guard let self else { return }
            self.isReading = false
            if let result {
                self.entries = result
                self.readDate = Date()
                self.error = nil
            } else {
                self.error = "Lecture impossible\u{00A0}: la commande netstat n’a pas répondu."
            }
        }
    }

    /// Route par défaut utilisée par le système pour une famille, à défaut la première trouvée.
    func mainDefault(_ family: RouteFamily) -> RouteEntry? {
        let defaults = entries.filter { $0.isDefault && $0.family == family }
        return defaults.first(where: \.isPrimaryDefault) ?? defaults.first
    }

    func defaultCount(_ family: RouteFamily) -> Int {
        entries.filter { $0.isDefault && $0.family == family }.count
    }
}
