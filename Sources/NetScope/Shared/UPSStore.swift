import Foundation
import NetScopeCore

/// Note 98 : derniers relevés des onduleurs, un fichier par site (`sites/<clé>/onduleurs.json` dans
/// Application Support/NetScope), comme les consommables des imprimantes (PrinterStore). Un relevé
/// est rangé sous l'adresse MAC de l'onduleur, dans le dossier du site actif : l'IP seule ne
/// choisit jamais le site ni l'appareil. Sans MAC, le relevé est affiché sans être conservé. Lecture SNMP seulement sur clic (« Lire
/// l'onduleur ») ou par la sonde ; en démonstration et pendant les captures, rien n'est lu sur le
/// réseau ni écrit sur le disque.
@MainActor
final class UPSStore: ObservableObject {
    static let shared = UPSStore()

    @Published private(set) var revision = 0
    /// Clés (site|appareil) en cours de lecture.
    @Published private(set) var reading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]

    let isDemo: Bool
    private let files: SiteFiles
    private var sites: [String: [String: UPSReading]] = [:]
    /// Relevés d'appareils sans MAC (site|IP) : affichés sur la fiche le temps de la session, jamais
    /// enregistrés ni repris par le rapport, l'Inventaire ou un autre appareil.
    private var unsaved: [String: UPSReading] = [:]
    static let noMACNotice = "MAC inconnue\u{00A0}: relevé non conservé"
    static let fileName = "onduleurs.json"

    init(demo: Bool = Launcher.isDemo || RegEnvironment.isSnapshot, files: SiteFiles = .standard) {
        isDemo = demo
        self.files = files
        if demo { sites[SiteModel.shared.activeKey] = UPSDemo.readings() }
    }

    /// Clé d'un appareil dans le fichier du site : sa MAC (nil sans MAC : rien n'est conservé).
    static func deviceKey(_ device: Device) -> String? { device.mac?.description }

    /// Jeton de lecture en cours et d'erreur (site|MAC, ou site|ip:IP sans MAC, jamais conservé).
    private static func token(_ device: Device, site: String) -> String {
        site + "|" + (deviceKey(device) ?? "ip:" + device.ip.description)
    }

    func readings(siteKey: String) -> [String: UPSReading] {
        if let cached = sites[siteKey] { return cached }
        guard !isDemo else { return [:] }
        let url = files.folder(for: siteKey).appendingPathComponent(Self.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: UPSReading].self, from: $0) } ?? [:]
        sites[siteKey] = loaded
        return loaded
    }

    func reading(for device: Device, siteKey: String? = nil) -> UPSReading? {
        let site = siteKey ?? SiteModel.shared.activeKey
        guard let key = Self.deviceKey(device) else { return unsaved[Self.token(device, site: site)] }
        return readings(siteKey: site)[key]
    }

    /// Vrai si le relevé affiché pour cet appareil n'est pas conservé (MAC inconnue).
    func isUnsaved(_ device: Device) -> Bool {
        device.mac == nil && unsaved[Self.token(device, site: SiteModel.shared.activeKey)] != nil
    }

    func isReading(_ device: Device) -> Bool { reading.contains(Self.token(device, site: SiteModel.shared.activeKey)) }
    func error(for device: Device) -> String? { errors[Self.token(device, site: SiteModel.shared.activeKey)] }

    /// « Lire l'onduleur » : lecture SNMP de l'UPS-MIB et des MIB des fabricants (identifiants du site).
    func read(_ device: Device) {
        let site = SiteModel.shared.activeKey
        let key = Self.deviceKey(device)
        let token = Self.token(device, site: site)
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
                let result = try await UPSMIB.read(client: SNMPClient(target: target))
                guard SiteModel.shared.activeKey == site else {
                    errors[token] = "Site changé pendant la lecture\u{00A0}: rien n’est enregistré"
                    return
                }
                if let key {
                    store(result, key: key, siteKey: site)
                } else {
                    unsaved[token] = result
                    revision += 1
                }
            } catch is CancellationError {
                return
            } catch {
                errors[token] = (error as? LocalizedError)?.errorDescription ?? "Lecture SNMP impossible"
            }
        }
    }

    /// Relevé fait ailleurs (sonde de Surveillance) : rangé sous la MAC de l'appareil, jamais par l'IP seule.
    func record(_ result: UPSReading, for device: Device, siteKey: String) {
        guard let mac = device.mac else { return }
        store(result, key: mac.description, siteKey: siteKey)
    }

    private func store(_ result: UPSReading, key: String, siteKey: String) {
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
            AppLog.shared.error("Onduleurs", "Enregistrement du relevé impossible\u{00A0}: \(error.localizedDescription)")
        }
    }

    /// Onduleurs du site pour le rapport : appareils de l'inventaire du site qui ont un relevé.
    func reportUnits(devices: [Device], siteKey: String) -> [ReportUPS] {
        let stored = readings(siteKey: siteKey)
        return devices.compactMap { device in
            guard let key = Self.deviceKey(device), let reading = stored[key] else { return nil }
            return ReportUPS(name: device.displayName, ip: device.ip.description, reading: reading)
        }
    }
}
