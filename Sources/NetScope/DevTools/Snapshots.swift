import AppKit
import NetScopeCore
import SwiftUI

// Outil de développement :
//   NetScope --snapshot <dossier> [--demo]
// dessine chaque écran en PNG 1440 × 900, hors de l'écran (aucune fenêtre visible), puis quitte.
// Avec --demo, les appareils de démonstration des croquis sont chargés. Aucun accès réseau,
// rien n'est lu ni écrit dans ~/Library/Application Support/NetScope/.

@MainActor
enum Snapshots {
    static let size = CGSize(width: 1440, height: 900)

    static func run(arguments: [String]) -> Never {
        let app = NSApplication.shared
        // Pas d'icône dans le Dock ni de menu : le processus reste en arrière-plan.
        app.setActivationPolicy(.prohibited)
        setvbuf(stdout, nil, _IOLBF, 0)

        let index = arguments.firstIndex(of: "--snapshot")!
        let next = index + 1 < arguments.count ? arguments[index + 1] : ""
        let path = next.isEmpty || next.hasPrefix("--") ? NSTemporaryDirectory() + "netscope-snapshots" : next
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let demo = arguments.contains("--demo")

        Task { @MainActor in
            let ok = await renderAll(into: directory, demo: demo)
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    static func renderAll(into directory: URL, demo: Bool) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Erreur : impossible de créer \(directory.path) : \(error.localizedDescription)")
            return false
        }

        let state = AppState(store: nil)
        if demo { DemoData.apply(to: state) }

        let hosting = NSHostingView(rootView: ContentView()
            .environmentObject(state)
            .frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)

        // Fenêtre sans bordure placée loin hors de l'écran : SwiftUI a besoin d'une fenêtre pour dessiner.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        var ok = true
        for (number, screen) in Screen.allCases.enumerated() {
            state.screen = screen
            try? await Task.sleep(nanoseconds: 400_000_000)
            let url = directory.appendingPathComponent(String(format: "%02d-%@.png", number + 1, screen.rawValue))
            if write(hosting, to: url) {
                print("Capture : \(url.path)")
            } else {
                print("Erreur : capture impossible de « \(screen.title) »")
                ok = false
            }
        }
        if demo { ok = RapportPDFCheck.write(into: directory, state: state) && ok }
        return ok
    }

    /// Dessine la vue dans une image de 1440 × 900 pixels exactement (échelle 1).
    private static func write(_ view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
