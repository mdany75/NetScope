import Foundation
import IOKit
import NetScopeCore

/// Note 86 : application À CHAUD des changements reçus d'un autre Mac. Chaque fichier ou réglage
/// synchronisé a ici le magasin qui le garde en mémoire et sa méthode de relecture : le
/// changement est écrit sur le disque (ou dans les préférences), puis le magasin relit. Un
/// fichier sans magasin connu ici attend le redémarrage (`applyAndRelaunch`, dernier recours).
@MainActor
enum RegSyncReload {
    /// Fichiers relus à chaud (motifs à la fnmatch).
    static let hotFiles = [
        SiteFiles.listName, "sites/*/" + SiteFiles.inventoryName, "sites/*/" + SiteFiles.notesName, "sites/*/" + SiteFiles.resultsName,
        "sites/*/" + WifiRoomSurvey.fileName, "sites/*/" + TopoManualLayout.fileName,
        "connexions.json", "rustdesk.json", "rustdesk-serveur.json", QuickLoginMemory.fileName, "identifiants.json",
        "surveillance.json", "outils.json", "speedtest.json", "rapports/planifies.json", "appareils-saisis.json",
    ]

    /// Préférences relues à chaud par leur magasin ; les autres sont lues par l'app au moment
    /// où elle s'en sert (écrites dans les préférences, elles prennent effet aussitôt).
    static let hotPreferences = [
        "reglages.scan.*", "reglages.general.*", "reglages.switchs.*", "reglages.export.*", "reglages.raccourcis",
        "reglages.notifications", "alertes.reglages", "NetScope.switchs.hotes", "NetScope.switchs.ignores",
        "NetScope.switchs.decouverts", ConfigCollection.fortiGates.key,
    ]

    static func isHot(file path: String) -> Bool { hotFiles.contains { ConfigMatch.glob($0, path) } }

    /// Écrit d'abord ce qui est en mémoire : la synchronisation et l'application voient l'état actuel.
    static func flushStores() {
        MonStore.shared.save()
        InvModel.shared.flushPendingWrites()
    }

    /// Relit les magasins touchés par les fichiers et préférences appliqués.
    static func reload(files: Set<String>, preferences: Set<String>, state: AppState?) {
        func touched(_ pattern: String) -> [String] { files.filter { ConfigMatch.glob(pattern, $0) } }
        func siteKey(_ path: String) -> String { path.split(separator: "/").dropFirst().first.map(String.init) ?? SiteFiles.noSiteKey }
        if files.contains(SiteFiles.listName) { SiteModel.shared.reloadFromDisk() }
        for path in touched("sites/*/" + SiteFiles.inventoryName) { InvModel.shared.reloadFromDisk(siteKey: siteKey(path)) }
        if touched("sites/*/" + SiteFiles.notesName).contains(where: { siteKey($0) == SiteModel.shared.activeKey }) {
            DeviceNotesStore.shared.reloadFromDisk()
        }
        for path in touched("sites/*/" + SiteFiles.resultsName) { SiteModel.shared.reloadResults(siteKey: siteKey(path)) }
        for path in touched("sites/*/" + WifiRoomSurvey.fileName) { WifiSurveyStore.shared.reloadFromDisk(siteKey: siteKey(path)) }
        for path in touched("sites/*/" + TopoManualLayout.fileName) { TopoLayoutStore.shared.forget(siteKey(path)) }
        if files.contains("connexions.json") { RemoteModel.shared.reloadFromDisk() }
        if files.contains("rustdesk.json") { RustDeskModel.shared.reloadFromDisk() }
        if files.contains("rustdesk-serveur.json") { RustDeskServerModel.shared.reloadFromDisk() }
        if files.contains(QuickLoginMemory.fileName) { QuickLoginModel.shared.reloadFromDisk() }
        if files.contains("identifiants.json") { RegRemoteCredentialStore.shared.reloadFromDisk() }
        if files.contains("surveillance.json") { MonStore.shared.reloadFromDisk() }
        if files.contains("outils.json") { ToolStore.shared.reloadFromDisk() }
        if files.contains("speedtest.json") { SpeedtestModel.shared.reloadFromDisk() }
        if files.contains("rapports/planifies.json") { RapportScheduleStore.shared.reloadFromDisk() }
        if files.contains("appareils-saisis.json") { state?.reloadManualFromDisk() }

        func pref(_ pattern: String) -> Bool { preferences.contains { ConfigMatch.glob(pattern, $0) } }
        if pref("reglages.scan.*") || pref("reglages.general.*") || pref("reglages.switchs.*") || pref("reglages.export.*") {
            RegPrefs.shared.reloadFromDisk()
        }
        if pref("reglages.raccourcis") { RegShortcutStore.shared.reloadFromDisk() }
        if pref("reglages.notifications") { RegNotifStore.shared.reloadFromDisk() }
        if pref("alertes.reglages") { AlertDispatcher.shared.reloadFromDisk() }
        if pref("NetScope.switchs.*") { SwitchStore.shared.reloadFromDisk() }
        if pref(ConfigCollection.fortiGates.key) { FortiGateStore.shared.reloadFromDisk() }
    }
}

/// Nom commercial du Mac (« MacBook Pro (14 pouces, 2023) »), publié pour les autres Mac.
enum RegSyncDeviceInfo {
    static let model: String = {
        // Apple silicon : nom du produit dans l'arbre des périphériques.
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            if let value = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                let name = String(decoding: value.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        // Sinon l'identifiant du modèle (« MacBookPro16,1 ») rendu lisible.
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let identifier = String(cString: buffer)
        let names = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"),
                     ("iMac", "iMac"), ("MacBook", "MacBook")]
        return names.first { identifier.hasPrefix($0.0) }?.1 ?? identifier
    }()
}
