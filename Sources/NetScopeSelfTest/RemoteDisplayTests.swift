import Foundation
import NetScopeCore

// Accès distant : fenêtre ou plein écran (fichier .rdp, échelle VNC, anciennes connexions).
// Aucun accès réseau.

func registerRemoteDisplayTests(_ suite: TestSuite) {
    func rdpLines(_ display: RemoteDisplaySettings?) -> [String] {
        let c = RemoteConnection(name: "WKS346", proto: .rdp, host: "10.182.122.117", username: "CORP\\dmenard", display: display)
        return RemoteLauncher.rdpFile(for: c).components(separatedBy: "\r\n")
    }

    suite.add("Accès : .rdp en plein écran (comportement d'avant)") {
        let lines = rdpLines(nil)
        try expect(lines.contains("screen mode id:i:2"), "plein écran par défaut")
        try expect(lines.contains("use multimon:i:0"), "un seul écran")
        try expect(lines.contains("dynamic resolution:i:1"), "résolution dynamique")
        try expect(lines.contains("smart sizing:i:1"), "mise à l'échelle")
        try expect(!lines.contains { $0.hasPrefix("desktopwidth") }, "pas de largeur en plein écran")
        // Le reste du fichier ne change pas.
        for line in ["prompt for credentials:i:1", "session bpp:i:32", "redirectclipboard:i:1", "redirectprinters:i:0",
                     "drivestoredirect:s:", "audiomode:i:0", "authentication level:i:2", "enablecredsspsupport:i:1"] {
            try expect(lines.contains(line), "ligne conservée : \(line)")
        }
        try expectEqual(lines[0], "full address:s:10.182.122.117:3389", "adresse en premier")
        try expectEqual(lines[1], "username:s:CORP\\dmenard", "utilisateur en second")
        // Plein écran sur tous les écrans ; la taille de fenêtre est ignorée.
        let multi = rdpLines(RemoteDisplaySettings(mode: .fullScreen, windowSize: .r1920x1080, allMonitors: true))
        try expect(multi.contains("use multimon:i:1"), "tous les écrans")
        try expect(multi.contains("screen mode id:i:2"), "plein écran")
        try expect(!multi.contains { $0.hasPrefix("desktopwidth") }, "taille ignorée en plein écran")
    }

    suite.add("Accès : .rdp en fenêtre, chaque taille") {
        let fit = rdpLines(RemoteDisplaySettings(mode: .window, windowSize: .fit))
        try expect(fit.contains("screen mode id:i:1"), "fenêtre")
        try expect(fit.contains("dynamic resolution:i:1"), "ajustée : résolution dynamique")
        try expect(fit.contains("smart sizing:i:1"), "ajustée : mise à l'échelle")
        try expect(!fit.contains { $0.hasPrefix("desktopwidth") || $0.hasPrefix("desktopheight") }, "ajustée : sans taille")

        let sizes: [(RemoteWindowSize, Int, Int)] = [(.r1280x800, 1280, 800), (.r1440x900, 1440, 900), (.r1920x1080, 1920, 1080)]
        for (size, width, height) in sizes {
            let lines = rdpLines(RemoteDisplaySettings(mode: .window, windowSize: size))
            try expect(lines.contains("screen mode id:i:1"), "\(size.rawValue) : fenêtre")
            try expect(lines.contains("desktopwidth:i:\(width)"), "\(size.rawValue) : largeur")
            try expect(lines.contains("desktopheight:i:\(height)"), "\(size.rawValue) : hauteur")
            try expect(lines.contains("dynamic resolution:i:0"), "\(size.rawValue) : taille fixe")
            try expect(lines.contains("smart sizing:i:1"), "\(size.rawValue) : réduite à la fenêtre au besoin")
            try expect(lines.contains("use multimon:i:0"), "\(size.rawValue) : un écran")
            let screen = lines.firstIndex(of: "screen mode id:i:1") ?? -1
            try expectEqual(lines.firstIndex(of: "desktopwidth:i:\(width)"), screen + 1, "\(size.rawValue) : largeur après le mode")
        }

        let custom = rdpLines(RemoteDisplaySettings(mode: .window, windowSize: .custom, customWidth: 1600, customHeight: 1000, allMonitors: true))
        try expect(custom.contains("desktopwidth:i:1600") && custom.contains("desktopheight:i:1000"), "personnalisée")
        try expect(custom.contains("use multimon:i:1"), "personnalisée : tous les écrans")
        let clamped = rdpLines(RemoteDisplaySettings(mode: .window, windowSize: .custom, customWidth: 99_999, customHeight: 10))
        try expect(clamped.contains("desktopwidth:i:7680") && clamped.contains("desktopheight:i:480"), "personnalisée bornée")

        var connection = RemoteConnection(name: "X", proto: .rdp, host: "10.0.0.1",
                                          display: RemoteDisplaySettings(mode: .window, windowSize: .custom, customWidth: 100, customHeight: 100_000))
        connection = try connection.validated()
        try expectEqual(connection.display.customWidth, 640, "validation : largeur bornée")
        try expectEqual(connection.display.customHeight, 4320, "validation : hauteur bornée")
    }

    suite.add("Accès : choix rapide, résumé et échelle VNC") {
        let saved = RemoteDisplaySettings(mode: .window, windowSize: .r1440x900)
        try expectEqual(saved.with(mode: .fullScreen).mode, .fullScreen, "plein écran pour cette fois")
        try expectEqual(saved.with(mode: .fullScreen).windowSize, .r1440x900, "taille conservée")
        try expectEqual(saved.summary(for: .rdp), "Fenêtre · 1440\u{00A0}×\u{00A0}900", "résumé RDP fenêtre")
        try expectEqual(RemoteDisplaySettings(mode: .fullScreen, allMonitors: true).summary(for: .rdp),
                        "Plein écran · tous les écrans", "résumé RDP plein écran")
        try expectEqual(RemoteDisplaySettings(mode: .window).summary(for: .rdp), "Fenêtre · ajustée à la fenêtre", "résumé ajusté")
        try expectEqual(RemoteDisplaySettings(mode: .window, vncScale: .actual).summary(for: .vnc), "Fenêtre · taille réelle", "résumé VNC")
        try expectEqual(RemoteDisplaySettings.defaults(for: .vnc).summary(for: .vnc), "Fenêtre", "VNC par défaut")
        try expectEqual(RemoteVNCScale.automatic.shouldScaleScreen, nil, "réglage de Partage d'écran inchangé")
        try expectEqual(RemoteVNCScale.fit.shouldScaleScreen, true, "ajuster")
        try expectEqual(RemoteVNCScale.actual.shouldScaleScreen, false, "taille réelle")
        // L'URL vnc:// ne change pas selon l'affichage.
        let vnc = RemoteConnection(name: "Mac", proto: .vnc, host: "10.182.122.135", username: "dany",
                                   display: RemoteDisplaySettings(mode: .fullScreen, vncScale: .fit))
        try expectEqual(try RemoteLauncher.plan(for: vnc), .url(URL(string: "vnc://dany@10.182.122.135")!), "URL VNC")
    }

    suite.add("Accès : fenêtre de Partage d'écran à passer en plein écran") {
        typealias W = RemoteFullScreenTarget.Window
        let connections = W(title: "Partage d’écran", subrole: "AXStandardWindow", isNew: false, canFullScreen: true)
        let dialog = W(title: "", subrole: "AXDialog", isNew: true, canFullScreen: false)
        let session = W(title: "10.182.122.135", subrole: "AXStandardWindow", isNew: true, canFullScreen: true)
        try expectEqual(RemoteFullScreenTarget.pick([connections, dialog], host: "10.182.122.135"), nil, "identification en cours : attendre")
        try expectEqual(RemoteFullScreenTarget.pick([connections, dialog, session], host: "10.182.122.135"), 2, "fenêtre de session")
        let renamed = W(title: "Mac mini de Dany", subrole: "AXStandardWindow", isNew: true, canFullScreen: true)
        try expectEqual(RemoteFullScreenTarget.pick([connections, renamed], host: "10.182.122.135"), 1, "seule nouvelle fenêtre")
        let other = W(title: "Autre", subrole: "AXStandardWindow", isNew: true, canFullScreen: true)
        try expectEqual(RemoteFullScreenTarget.pick([renamed, other], host: "10.182.122.135"), nil, "deux nouvelles sans l'hôte : ne rien deviner")
        var already = session
        already.isFullScreen = true
        try expectEqual(RemoteFullScreenTarget.pick([already], host: "10.182.122.135"), nil, "déjà en plein écran")
    }

    suite.add("Accès : connexions enregistrées avant les réglages d'affichage") {
        let json = """
        {"version":1,"connections":[
          {"id":"6F1C2A3E-0000-4000-8000-000000000001","name":"WKS346","proto":"rdp","host":"10.182.122.117","port":3389,
           "username":"CORP\\\\dmenard","folder":"Siège › Postes","isFavorite":true,"note":"","createdAt":"2026-10-01T12:00:00Z"},
          {"id":"6F1C2A3E-0000-4000-8000-000000000002","name":"Mac","proto":"vnc","host":"10.182.122.135","port":5900,
           "username":"dany","folder":"","isFavorite":false,"note":"","lastConnected":"2026-11-02T09:00:00Z","createdAt":"2026-10-01T12:00:00Z"},
          {"id":"6F1C2A3E-0000-4000-8000-000000000003","name":"Partiel","proto":"rdp","host":"10.0.0.9","port":3389,
           "username":"","folder":"","isFavorite":false,"note":"","createdAt":"2026-10-01T12:00:00Z",
           "display":{"mode":"fenetre","windowSize":"1920x1080","inconnu":42}}
        ]}
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-display-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("connexions.json")
        try Data(json.utf8).write(to: url)
        let store = RemoteConnectionStore(url: url)
        guard let loaded = store.load() else { throw TestFailure(message: "ancien fichier illisible", file: #fileID, line: #line) }
        try expectEqual(loaded.count, 3, "trois connexions")
        try expectEqual(loaded[0].display, RemoteDisplaySettings.defaults(for: .rdp), "RDP : plein écran comme avant")
        try expectEqual(loaded[0].username, "CORP\\dmenard", "utilisateur relu")
        try expect(RemoteLauncher.rdpFile(for: loaded[0]).contains("screen mode id:i:2"), "RDP : même fichier qu'avant")
        try expectEqual(loaded[1].display, RemoteDisplaySettings.defaults(for: .vnc), "VNC : fenêtre, échelle de l'app")
        try expect(loaded[1].lastConnected != nil, "date relue")
        try expectEqual(loaded[2].display.mode, .window, "réglage partiel : mode")
        try expectEqual(loaded[2].display.windowSize, .r1920x1080, "réglage partiel : taille")
        try expectEqual(loaded[2].display.vncScale, .automatic, "réglage partiel : défaut pour le reste")

        // Aller-retour avec les nouveaux champs.
        var edited = loaded
        edited[1].display = RemoteDisplaySettings(mode: .fullScreen, vncScale: .actual)
        try store.save(edited)
        try expectEqual(store.load(), edited, "aller-retour avec l'affichage")
    }
}
