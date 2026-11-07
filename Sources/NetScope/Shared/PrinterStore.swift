import Foundation
import NetScopeCore

/// Note 91 : derniers relevés des consommables des imprimantes, un fichier par site
/// (`sites/<clé>/imprimantes.json` dans Application Support/NetScope). Un relevé est rangé sous
/// l'adresse MAC de l'imprimante (l'IP seulement à défaut), dans le dossier du site actif : l'IP
/// seule ne choisit jamais le site. Lecture SNMP seulement sur clic (« Lire les consommables ») ;
/// en démonstration et pendant les captures, rien n'est lu sur le réseau ni écrit sur le disque.
@MainActor
final class PrinterStore: ObservableObject {
    static let shared = PrinterStore()

    @Published private(set) var revision = 0
    /// Clés (site|appareil) en cours de lecture.
    @Published private(set) var reading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]

    let isDemo: Bool
    private let files: SiteFiles
    private var sites: [String: [String: PrinterReading]] = [:]
    static let fileName = "imprimantes.json"

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot, files: SiteFiles = .standard) {
        isDemo = demo
        self.files = files
        if demo { sites[SiteModel.shared.activeKey] = PrinterDemo.readings() }
    }

    /// Clé d'un appareil dans le fichier du site : MAC, sinon IP.
    static func deviceKey(_ device: Device) -> String { device.mac?.description ?? device.ip.description }

    func readings(siteKey: String) -> [String: PrinterReading] {
        if let cached = sites[siteKey] { return cached }
        guard !isDemo else { return [:] }
        let url = files.folder(for: siteKey).appendingPathComponent(Self.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: PrinterReading].self, from: $0) } ?? [:]
        sites[siteKey] = loaded
        return loaded
    }

    func reading(for device: Device, siteKey: String? = nil) -> PrinterReading? {
        readings(siteKey: siteKey ?? SiteModel.shared.activeKey)[Self.deviceKey(device)]
    }

    func isReading(_ device: Device) -> Bool { reading.contains(SiteModel.shared.activeKey + "|" + Self.deviceKey(device)) }
    func error(for device: Device) -> String? { errors[SiteModel.shared.activeKey + "|" + Self.deviceKey(device)] }

    /// « Lire les consommables » : lecture SNMP de la Printer-MIB (identifiants du site).
    func read(_ device: Device) {
        let site = SiteModel.shared.activeKey
        let key = Self.deviceKey(device)
        let token = site + "|" + key
        guard !reading.contains(token) else { return }
        errors[token] = nil
        if isDemo {
            errors[token] = "Mode démonstration\u{00A0}: aucune requête SNMP."
            return
        }
        reading.insert(token)
        Task {
            let switches = SwitchStore.shared
            await switches.loadVault()
            defer { reading.remove(token) }
            guard let target = switches.snmpTarget(for: device.ip.description) else {
                errors[token] = "Aucun identifiant SNMP\u{00A0}: saisissez une communauté ou un utilisateur v3 dans Réglages › Identifiants"
                return
            }
            do {
                let result = try await PrinterMIB.read(client: SNMPClient(target: target))
                guard SiteModel.shared.activeKey == site else {
                    errors[token] = "Site changé pendant la lecture\u{00A0}: rien n’est enregistré"
                    return
                }
                store(result, key: key, siteKey: site)
            } catch is CancellationError {
                return
            } catch {
                errors[token] = (error as? LocalizedError)?.errorDescription ?? "Lecture SNMP impossible"
            }
        }
    }

    private func store(_ result: PrinterReading, key: String, siteKey: String) {
        var current = readings(siteKey: siteKey)
        current[key] = result
        sites[siteKey] = current
        revision += 1
        guard !isDemo else { return }
        let url = files.folder(for: siteKey).appendingPathComponent(Self.fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(current).write(to: url, options: .atomic)
        } catch {
            AppLog.shared.error("Imprimantes", "Enregistrement des consommables impossible\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Imprimantes du site pour le rapport : appareils de l'inventaire du site qui ont un relevé.
    func reportPrinters(devices: [Device], siteKey: String) -> [ReportPrinter] {
        let stored = readings(siteKey: siteKey)
        return devices.compactMap { device in
            guard let reading = stored[Self.deviceKey(device)] else { return nil }
            return ReportPrinter(name: device.displayName, ip: device.ip.description, model: device.hostname, reading: reading)
        }
    }
}
