import AppKit
import NetScopeCore
import SwiftUI

// Outil de développement :
//   NetScope --snapshot <dossier> [--demo] [--appearance light|dark] [--size <L>x<H>]
// dessine chaque écran en PNG (1440 × 900 en clair par défaut), hors de l'écran (aucune fenêtre
// visible), puis quitte. La fenêtre capturée est une vraie fenêtre à barre d'outils unifiée et
// barre latérale du système. Avec --demo, les appareils de démonstration des croquis sont chargés.
// Aucun accès réseau, rien n'est lu ni écrit dans ~/Library/Application Support/NetScope/.

@MainActor
enum Snapshots {
    static let defaultSize = CGSize(width: 1440, height: 900)

    struct Options {
        var directory: URL
        var demo = false
        var dark = false
        var size = CGSize(width: 1440, height: 900)
    }

    static func run(arguments: [String]) -> Never {
        // Première création de NSApp : une sous-classe qui se dit active, pour que la fenêtre capturée
        // ait l'aspect d'une fenêtre au premier plan sans voler le premier plan à l'utilisateur.
        let app = SnapshotApplication.shared
        // Pas d'icône dans le Dock ni de menu : le processus reste en arrière-plan.
        app.setActivationPolicy(.prohibited)
        setvbuf(stdout, nil, _IOLBF, 0)

        guard let options = parse(arguments) else { exit(2) }
        Task { @MainActor in
            let ok = await renderAll(options)
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    /// Lit `--snapshot <dossier>`, `--demo`, `--appearance light|dark` et `--size <L>x<H>`.
    static func parse(_ arguments: [String]) -> Options? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("--") ? nil : next
        }
        let path = value(after: "--snapshot") ?? NSTemporaryDirectory() + "netscope-snapshots"
        var options = Options(directory: URL(fileURLWithPath: path, isDirectory: true))
        options.demo = arguments.contains("--demo")
        if arguments.contains("--appearance") {
            switch value(after: "--appearance")?.lowercased() {
            case "dark", "sombre": options.dark = true
            case "light", "clair": options.dark = false
            default:
                print("Erreur : --appearance attend « light » ou « dark ».")
                return nil
            }
        }
        if arguments.contains("--size") {
            let parts = (value(after: "--size") ?? "").lowercased().split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  (600...4000).contains(width), (400...3000).contains(height) else {
                print("Erreur : --size attend une taille comme 1000x650 (de 600x400 à 4000x3000).")
                return nil
            }
            options.size = CGSize(width: width, height: height)
        }
        return options
    }

    static func renderAll(_ options: Options) async -> Bool {
        let directory = options.directory
        let size = options.size
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Erreur : impossible de créer \(directory.path) : \(error.localizedDescription)")
            return false
        }

        let state = AppState(store: nil)
        if options.demo { DemoData.apply(to: state) }
        let appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        // Les couleurs dynamiques lues hors d'une vue (NSApp) suivent aussi l'apparence demandée.
        NSApp.appearance = appearance

        SnapshotActiveState.forceActive = true
        let hosting = NSHostingView(rootView: ContentView().environmentObject(state)
            .modifier(SnapshotActiveState()))
        // La barre d'outils et le titre de SwiftUI passent dans la barre unifiée de la fenêtre.
        hosting.sceneBridgingOptions = [.toolbars, .title]

        // Vraie fenêtre à barre de titre, placée loin hors de l'écran : rien n'est visible.
        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.toolbarStyle = .unified
        window.contentView = hosting
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        var ok = true
        // NETSCOPE_ECRANS="switchs,wifi" : seulement ces écrans (captures plus rapides).
        let only = ProcessInfo.processInfo.environment["NETSCOPE_ECRANS"].map {
            Set($0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        // Capture d'un seul écran (galerie du README) : les démonstrations asynchrones (outils
        // courriel, SPF/DKIM…) n'ont pas le temps de finir en 450 ms ; on leur laisse un délai.
        if only != nil { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        for (number, screen) in Screen.allCases.enumerated() {
            if let only, !only.contains(screen.rawValue) { continue }
            state.screen = screen
            try? await Task.sleep(nanoseconds: 450_000_000)
            let url = directory.appendingPathComponent(String(format: "%02d-%@.png", number + 1, screen.rawValue))
            if write(window, size: size, to: url) {
                print("Capture : \(url.path)")
            } else {
                print("Erreur : capture impossible de « \(screen.title) »")
                ok = false
            }
        }
        if options.demo { ok = RapportPDFCheck.write(into: directory, state: state) && ok }
        // Note 78 : rapport « pour le fournisseur Internet » du ping continu.
        if options.demo { ok = PingISPReportCheck.write(into: directory) && ok }
        return ok
    }

    /// Dessine toute la fenêtre (barre d'outils comprise) dans une image de la taille demandée,
    /// à l'échelle 1.
    private static func write(_ window: NSWindow, size: CGSize, to url: URL) -> Bool {
        guard let frameView = window.contentView?.superview else { return false }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        frameView.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Fenêtre de capture : se présente comme la fenêtre active, pour que la barre d'outils et la
/// barre latérale aient leurs couleurs normales (et non l'aspect grisé d'une fenêtre en arrière-plan).
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Fenêtre hors écran : AppKit ne la ramène pas à la hauteur de l'écran (« --size 1440x2600 »
    // montre alors toute la page, sans défilement).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    // Méthodes internes d'AppKit qui décident de l'aspect actif (outil de développement seulement).
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
}

/// Application des captures : se présente comme active (barre d'outils et titre non grisés),
/// sans jamais passer au premier plan.
private final class SnapshotApplication: NSApplication {
    override var isActive: Bool { true }
}
