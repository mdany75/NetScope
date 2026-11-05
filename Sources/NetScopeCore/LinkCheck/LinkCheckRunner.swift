import Foundation

/// Avancement d'un bilan : une étape commence (`step` nil) ou se termine.
public struct LinkCheckProgress: Sendable {
    public var kind: LinkCheckStepKind
    public var step: LinkCheckStep?
}

/// Note 58 : enchaînement du bilan de raccordement.
///
/// Ordre : lien d'abord (sans lien, rien d'autre n'a de sens) ; l'écoute LLDP/CDP démarre aussitôt
/// et tourne pendant DHCP, passerelle, DNS et Internet (les annonces arrivent toutes les 30 s) ;
/// switch, VLAN et PoE se terminent en dernier. Sans adresse IPv4, passerelle, DNS et Internet
/// sont « non vérifiés » (le DHCP, lui, est mesuré : c'est justement ce qu'il faut savoir).
public enum LinkCheckRunner {
    public static func run(_ options: LinkCheckOptions, probes: any LinkCheckProbing, siteKey: String? = nil, siteName: String = "",
                           now: @escaping @Sendable () -> Date = { Date() },
                           progress: @escaping @Sendable (LinkCheckProgress) -> Void = { _ in }) async -> LinkCheckResult {
        let start = now()
        var steps: [LinkCheckStep] = []
        func finish(_ step: LinkCheckStep) {
            steps.append(step)
            progress(LinkCheckProgress(kind: step.kind, step: step))
        }
        func result(kind: String) -> LinkCheckResult {
            LinkCheckResult(date: start, siteKey: siteKey, siteName: siteName, location: options.location.trimmingCharacters(in: .whitespaces),
                            interfaceName: options.interfaceName, interfaceKind: kind, steps: steps,
                            duration: max(0, now().timeIntervalSince(start)))
        }

        progress(LinkCheckProgress(kind: .lien, step: nil))
        let measuredLink = await probes.link(options.interfaceName)
        finish(LinkCheckEvaluator.link(measuredLink, requested: options.interfaceName))
        guard let link = measuredLink, link.isActive != false else {
            for kind in LinkCheckStepKind.allCases where kind != .lien {
                finish(LinkCheckStep(kind: kind, status: .skipped, summary: "Non mesuré",
                                     explanation: "Pas de lien sur \(options.interfaceName)\u{00A0}: étape sautée."))
            }
            return result(kind: measuredLink?.kindLabel ?? "")
        }

        // Écoute LLDP/CDP en parallèle des autres étapes (pas en Wi-Fi).
        let listens = !link.isWireless && options.neighborSeconds > 0
        if listens {
            for kind in [LinkCheckStepKind.switchPort, .vlan, .poe] { progress(LinkCheckProgress(kind: kind, step: nil)) }
        }
        async let neighborMeasure = listen(probes, link: link, seconds: options.neighborSeconds, enabled: listens)

        progress(LinkCheckProgress(kind: .dhcp, step: nil))
        let dhcp = await probes.dhcp(on: link, seconds: options.dhcpSeconds)
        finish(LinkCheckEvaluator.dhcp(dhcp, link: link, allowed: options.allowedDHCPServers))

        let usable = link.hasUsableAddress
        progress(LinkCheckProgress(kind: .passerelle, step: nil))
        var gatewayMeasure: LinkCheckGatewayMeasure?
        if usable, let gateway = link.gateway {
            gatewayMeasure = await probes.gateway(gateway, count: options.pingCount, interval: options.pingInterval)
        }
        finish(LinkCheckEvaluator.gateway(gatewayMeasure, link: link))

        progress(LinkCheckProgress(kind: .dns, step: nil))
        var dnsMeasure: LinkCheckDNSMeasure?
        if usable, !options.dnsNames.isEmpty {
            dnsMeasure = await probes.dns(options.dnsNames, server: link.dnsServers.first)
        }
        finish(LinkCheckEvaluator.dns(dnsMeasure, link: link))

        progress(LinkCheckProgress(kind: .internet, step: nil))
        var internetMeasure: LinkCheckInternetMeasure?
        if usable { internetMeasure = await probes.internet(options.internetURL, expectedText: options.expectedInternetText) }
        finish(LinkCheckEvaluator.internet(internetMeasure, link: link))

        let neighbor = await neighborMeasure
        finish(LinkCheckEvaluator.switchPort(neighbor, link: link))
        finish(LinkCheckEvaluator.vlan(neighbor, link: link, expected: options.expectedVLAN))
        finish(LinkCheckEvaluator.poe(neighbor, link: link))
        return result(kind: link.kindLabel)
    }

    private static func listen(_ probes: any LinkCheckProbing, link: LinkCheckLink, seconds: TimeInterval,
                               enabled: Bool) async -> LinkCheckNeighborMeasure? {
        enabled ? await probes.neighbor(on: link, seconds: seconds) : nil
    }
}
