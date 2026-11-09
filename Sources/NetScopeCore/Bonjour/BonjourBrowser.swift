import Foundation

/// Furetage Bonjour réel (multidiffusion sur le réseau local) : jamais lancé par les tests ni en
/// capture. NetService résout l'hôte, le port et le TXT par mDNS seul, sans ouvrir de connexion
/// vers les appareils, ce que NWBrowser ne permet pas. Tous les rappels arrivent sur le fil principal.
@MainActor
public final class BonjourBrowser: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    public var onChange: (([BonjourService]) -> Void)?
    public var onDenied: (() -> Void)?

    private static let resolveTimeout: TimeInterval = 10
    /// Borne les types annoncés par le réseau : un appareil ne doit pas faire ouvrir des milliers de furetages.
    private static let maxBrowsers = 128

    private var browsers: [String: NetServiceBrowser] = [:]
    private var netServices: [String: NetService] = [:]
    private var found: [String: BonjourService] = [:]
    /// Un service est signalé une fois par interface : il ne part qu'au dernier retrait.
    private var announcements: [String: Int] = [:]

    public override init() { super.init() }

    public func start() {
        stop()
        browse(BonjourCatalog.enumerationType)
        BonjourCatalog.types.forEach(browse)
    }

    public func stop() {
        browsers.values.forEach {
            $0.delegate = nil
            $0.stop()
        }
        netServices.values.forEach {
            $0.delegate = nil
            $0.stop()
        }
        browsers = [:]
        netServices = [:]
        found = [:]
        announcements = [:]
    }

    private func browse(_ type: String) {
        guard browsers[type] == nil, browsers.count < Self.maxBrowsers else { return }
        let browser = NetServiceBrowser()
        browser.delegate = self
        browsers[type] = browser
        browser.searchForServices(ofType: type + ".", inDomain: "local.")
    }

    private func browsedType(_ browser: NetServiceBrowser) -> String? {
        browsers.first { $0.value === browser }?.key
    }

    private func key(_ service: NetService) -> String {
        BonjourService(type: service.type, instance: service.name, domain: service.domain).id
    }

    private func publish() { onChange?(Array(found.values)) }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if browsedType(browser) == BonjourCatalog.enumerationType {
            if let type = BonjourCatalog.typeFromEnumeration(name: service.name, type: service.type) { browse(type) }
            return
        }
        let id = key(service)
        announcements[id, default: 0] += 1
        if netServices[id] == nil {
            netServices[id] = service
            found[id] = BonjourService(type: service.type, instance: service.name, domain: service.domain)
            service.delegate = self
            service.resolve(withTimeout: Self.resolveTimeout)
        }
        if !moreComing { publish() }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browsedType(browser) != BonjourCatalog.enumerationType else { return }
        let id = key(service)
        announcements[id, default: 0] -= 1
        if announcements[id, default: 0] <= 0 {
            announcements[id] = nil
            netServices.removeValue(forKey: id)?.stop()
            found[id] = nil
        }
        if !moreComing { publish() }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        // Un type appris du réseau peut être refusé parce que non déclaré : seul le catalogue dit l'autorisation.
        guard let type = browsedType(browser), type == BonjourCatalog.enumerationType || BonjourCatalog.isKnown(type) else { return }
        if BonjourAccess.isDenied(errorCode: errorDict[NetService.errorCode]?.intValue ?? 0) { onDenied?() }
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        let id = key(sender)
        guard found[id] != nil else { return }
        let addresses = BonjourAddress.split(sender.addresses ?? [])
        found[id]?.host = sender.hostName
        found[id]?.port = sender.port > 0 ? sender.port : nil
        found[id]?.ipv4 = addresses.ipv4
        found[id]?.ipv6 = addresses.ipv6
        found[id]?.txt = sender.txtRecordData().map(BonjourTXT.decode) ?? [:]
        publish()
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        if BonjourAccess.isDenied(errorCode: errorDict[NetService.errorCode]?.intValue ?? 0) { onDenied?() }
    }
}
