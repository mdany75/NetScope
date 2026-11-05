import AppKit
import Foundation
import NetScopeCore

// Note 57 : sessions VNC de démonstration (--demo et captures). Le bureau distant est dessiné ici
// dans un tampon RFB, sans aucun réseau : un poste Windows 11 (WKS352, UltraVNC) et le Mac mini
// du croquis (docs/croquis/Remote.dc.html : Finder, Terminal, Dock).

@MainActor
enum VNCDemo {
    /// Connexion VNC du poste Windows ajoutée à la démonstration (capture NETSCOPE_REMOTE_VIEW=vnc).
    static let windowsName = "WKS352"

    /// Mot de passe « enregistré » au Trousseau en démonstration (aucun Trousseau touché).
    static var savedPassword = true

    struct Desktop {
        var framebuffer: RFBFramebuffer
        var name: String
        var security: RFBSecurityType
    }

    /// Bureau distant de la connexion : macOS pour un Mac, Windows sinon.
    static func desktop(for connection: RemoteConnection) -> Desktop {
        if connection.note.localizedCaseInsensitiveContains("mac") {
            return Desktop(framebuffer: mac(), name: "Macmini-de-Dany", security: .appleRemoteDesktop)
        }
        return Desktop(framebuffer: windows(host: connection.host), name: "WKS352 (UltraVNC)", security: .vncAuthentication)
    }

    // MARK: Dessin

    /// Contexte retourné (origine en haut à gauche) qui écrit directement dans un tampon RFB.
    private static func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> RFBFramebuffer {
        var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(context)
            NSGraphicsContext.current = previous
        }
        return RFBFramebuffer(width: width, height: height, pixels: pixels)
    }

    private static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, _ hex: UInt32, alpha: CGFloat = 1, radius: CGFloat = 0) {
        context.setFillColor(color(hex, alpha))
        if radius > 0 {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        } else {
            context.fill(rect)
        }
    }

    private static func stroke(_ context: CGContext, _ rect: CGRect, _ hex: UInt32, alpha: CGFloat = 1, radius: CGFloat = 0) {
        context.setStrokeColor(color(hex, alpha))
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, _ hex: UInt32, weight: NSFont.Weight = .regular,
                             mono: Bool = false, alpha: CGFloat = 1) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color(hex, alpha)) ?? .white,
        ]
        NSAttributedString(string: string, attributes: attributes).draw(at: point)
    }

    private static func centered(_ string: String, in rect: CGRect, size: CGFloat, _ hex: UInt32, weight: NSFont.Weight = .regular) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color(hex)) ?? .white])
        let measured = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - measured.width / 2, y: rect.minY))
    }

    private static func shadow(_ context: CGContext, _ rect: CGRect, radius: CGFloat) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.35))
        fill(context, rect, 0x000000, alpha: 1, radius: radius)
        context.restoreGState()
    }

    // MARK: Windows 11 (WKS352)

    static func windows(host: String) -> RFBFramebuffer {
        let width = 1600, height = 900
        return render(width: width, height: height) { ctx in
            // Fond « Bloom » : dégradé bleu et pétales clairs.
            let gradient = CGGradient(colorsSpace: nil, colors: [color(0x0A1F55), color(0x1452B8), color(0x5FA4EE)] as CFArray,
                                      locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
            for (index, petal) in [(1020, 420, 520, 300), (1110, 380, 420, 420), (960, 470, 380, 260), (1180, 470, 300, 330)].enumerated() {
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(petal.0), y: CGFloat(petal.1))
                ctx.rotate(by: CGFloat(index) * 0.55 - 0.6)
                ctx.setFillColor(color([0x7CC3FF, 0xA9D8FF, 0x3D8BEA, 0xCFE8FF][index], 0.38))
                ctx.fillEllipse(in: CGRect(x: -CGFloat(petal.2) / 2, y: -CGFloat(petal.3) / 2, width: CGFloat(petal.2), height: CGFloat(petal.3)))
                ctx.restoreGState()
            }

            // Icônes du bureau.
            let icons: [(String, UInt32)] = [("Corbeille", 0xD1D5DB), ("Ce PC", 0x60A5FA), ("Outils réseau", 0xFBBF24), ("Putty", 0x93C5FD)]
            for (index, icon) in icons.enumerated() {
                let y = CGFloat(18 + index * 96)
                fill(ctx, CGRect(x: 30, y: y, width: 44, height: 40), icon.1, radius: 6)
                fill(ctx, CGRect(x: 30, y: y, width: 44, height: 10), 0xFFFFFF, alpha: 0.35, radius: 4)
                centered(icon.0, in: CGRect(x: 2, y: y + 46, width: 100, height: 18), size: 12, 0xFFFFFF)
            }

            // Explorateur de fichiers (derrière).
            let explorer = CGRect(x: 170, y: 70, width: 760, height: 470)
            shadow(ctx, explorer, radius: 8)
            fill(ctx, explorer, 0xF3F3F3, radius: 8)
            fill(ctx, CGRect(x: explorer.minX, y: explorer.minY + 40, width: explorer.width, height: 44), 0xFBFBFB)
            text("Ce PC", at: CGPoint(x: explorer.minX + 16, y: explorer.minY + 12), size: 13, 0x111827)
            for (index, glyph) in ["—", "☐", "✕"].enumerated() {
                text(glyph, at: CGPoint(x: explorer.maxX - 130 + CGFloat(index) * 44, y: explorer.minY + 10), size: 13, 0x374151)
            }
            fill(ctx, CGRect(x: explorer.minX + 110, y: explorer.minY + 50, width: 420, height: 26), 0xFFFFFF, radius: 4)
            stroke(ctx, CGRect(x: explorer.minX + 110, y: explorer.minY + 50, width: 420, height: 26), 0xD1D5DB, radius: 4)
            text("›  Ce PC", at: CGPoint(x: explorer.minX + 120, y: explorer.minY + 55), size: 12, 0x374151)
            fill(ctx, CGRect(x: explorer.maxX - 220, y: explorer.minY + 50, width: 200, height: 26), 0xFFFFFF, radius: 4)
            text("Rechercher dans : Ce PC", at: CGPoint(x: explorer.maxX - 210, y: explorer.minY + 55), size: 12, 0x6B7280)
            let sidebar = ["Accueil", "Galerie", "Bureau", "Téléchargements", "Documents", "Images", "Ce PC", "Réseau"]
            for (index, item) in sidebar.enumerated() {
                let y = explorer.minY + 98 + CGFloat(index) * 30
                if item == "Ce PC" { fill(ctx, CGRect(x: explorer.minX + 6, y: y - 4, width: 168, height: 26), 0xE5E7EB, radius: 4) }
                text(item, at: CGPoint(x: explorer.minX + 18, y: y), size: 12, 0x1F2937)
            }
            fill(ctx, CGRect(x: explorer.minX + 180, y: explorer.minY + 84, width: 1, height: explorer.height - 84), 0xE5E7EB)
            text("Périphériques et lecteurs", at: CGPoint(x: explorer.minX + 200, y: explorer.minY + 98), size: 13, 0x111827, weight: .semibold)
            let drives: [(String, String, Double)] = [("Windows (C:)", "142 Go libres sur 476 Go", 0.7), ("DONNÉES (D:)", "611 Go libres sur 931 Go", 0.34)]
            for (index, drive) in drives.enumerated() {
                let x = explorer.minX + 200 + CGFloat(index) * 270
                fill(ctx, CGRect(x: x, y: explorer.minY + 130, width: 40, height: 30), 0x9CA3AF, radius: 4)
                text(drive.0, at: CGPoint(x: x + 52, y: explorer.minY + 128), size: 12, 0x111827)
                fill(ctx, CGRect(x: x + 52, y: explorer.minY + 148, width: 180, height: 8), 0xE5E7EB, radius: 2)
                fill(ctx, CGRect(x: x + 52, y: explorer.minY + 148, width: 180 * drive.2, height: 8), 0x2563EB, radius: 2)
                text(drive.1, at: CGPoint(x: x + 52, y: explorer.minY + 162), size: 11, 0x6B7280)
            }
            text("Emplacements réseau", at: CGPoint(x: explorer.minX + 200, y: explorer.minY + 210), size: 13, 0x111827, weight: .semibold)
            for (index, share) in ["\\\\NAS-SYNO\\sauvegardes (Z:)", "\\\\SRV-FICHIERS\\partage (S:)"].enumerated() {
                let x = explorer.minX + 200 + CGFloat(index) * 270
                fill(ctx, CGRect(x: x, y: explorer.minY + 240, width: 40, height: 30), 0x60A5FA, radius: 4)
                text(share, at: CGPoint(x: x + 52, y: explorer.minY + 246), size: 12, 0x111827)
            }
            text("8 éléments", at: CGPoint(x: explorer.minX + 12, y: explorer.maxY - 22), size: 11, 0x6B7280)

            // Invite de commandes (devant).
            let console = CGRect(x: 640, y: 210, width: 820, height: 480)
            shadow(ctx, console, radius: 8)
            fill(ctx, console, 0x0C0C0C, radius: 8)
            fill(ctx, CGRect(x: console.minX, y: console.minY, width: console.width, height: 38), 0x202020, radius: 8)
            fill(ctx, CGRect(x: console.minX, y: console.minY + 30, width: console.width, height: 8), 0x202020)
            fill(ctx, CGRect(x: console.minX + 8, y: console.minY + 4, width: 220, height: 34), 0x0C0C0C, radius: 6)
            text("C:\\  Invite de commandes", at: CGPoint(x: console.minX + 20, y: console.minY + 12), size: 12, 0xF3F4F6)
            text("+", at: CGPoint(x: console.minX + 240, y: console.minY + 9), size: 15, 0xD1D5DB)
            for (index, glyph) in ["—", "☐", "✕"].enumerated() {
                text(glyph, at: CGPoint(x: console.maxX - 130 + CGFloat(index) * 44, y: console.minY + 10), size: 13, 0xE5E7EB)
            }
            let lines = [
                "Microsoft Windows [version 10.0.22631.4460]",
                "(c) Microsoft Corporation. Tous droits réservés.",
                "",
                "C:\\Users\\dmenard>ipconfig",
                "",
                "Configuration IP de Windows",
                "",
                "Carte Ethernet Ethernet :",
                "",
                "   Suffixe DNS propre à la connexion. . . : corp.local",
                "   Adresse IPv4. . . . . . . . . . . . . .: \(host)",
                "   Masque de sous-réseau. . . . . . . . . : 255.255.255.0",
                "   Passerelle par défaut. . . . . . . . . : 10.182.122.1",
                "",
                "C:\\Users\\dmenard>ping -n 2 10.182.122.1",
                "",
                "Envoi d’une requête « Ping »  10.182.122.1 avec 32 octets de données :",
                "Réponse de 10.182.122.1 : octets=32 temps<1ms TTL=255",
                "Réponse de 10.182.122.1 : octets=32 temps<1ms TTL=255",
                "",
                "C:\\Users\\dmenard>_",
            ]
            for (index, line) in lines.enumerated() {
                text(line, at: CGPoint(x: console.minX + 16, y: console.minY + 50 + CGFloat(index) * 19), size: 13, 0xCCCCCC, mono: true)
            }

            // Barre des tâches.
            let bar = CGRect(x: 0, y: CGFloat(height - 48), width: CGFloat(width), height: 48)
            fill(ctx, bar, 0xEEF1F6, alpha: 0.93)
            fill(ctx, CGRect(x: 0, y: bar.minY, width: bar.width, height: 1), 0xFFFFFF, alpha: 0.6)
            let apps: [UInt32] = [0x0078D4, 0x6B7280, 0xF59E0B, 0x16A34A, 0x0C0C0C, 0x7C3AED]
            let startX = CGFloat(width) / 2 - CGFloat(apps.count) * 22
            for (index, hex) in apps.enumerated() {
                let x = startX + CGFloat(index) * 44
                let cell = CGRect(x: x + 6, y: bar.minY + 8, width: 32, height: 32)
                if index == 4 { fill(ctx, cell.insetBy(dx: -3, dy: -2), 0xFFFFFF, alpha: 0.8, radius: 5) }
                if index == 0 {
                    // Logo Démarrer : quatre carrés.
                    for qx in 0..<2 { for qy in 0..<2 {
                        fill(ctx, CGRect(x: cell.minX + 6 + CGFloat(qx) * 11, y: cell.minY + 6 + CGFloat(qy) * 11, width: 9.5, height: 9.5), hex, radius: 1)
                    } }
                } else if index == 1 {
                    ctx.setStrokeColor(color(hex)); ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: CGRect(x: cell.minX + 8, y: cell.minY + 8, width: 13, height: 13))
                    ctx.move(to: CGPoint(x: cell.minX + 19, y: cell.minY + 19)); ctx.addLine(to: CGPoint(x: cell.minX + 25, y: cell.minY + 25)); ctx.strokePath()
                } else {
                    fill(ctx, cell.insetBy(dx: 4, dy: 4), hex, radius: 5)
                }
                if index == 3 || index == 4 { fill(ctx, CGRect(x: cell.midX - (index == 4 ? 8 : 3), y: bar.maxY - 5, width: index == 4 ? 16 : 6, height: 3), 0x0078D4, radius: 1.5) }
            }
            text("FRA", at: CGPoint(x: CGFloat(width) - 214, y: bar.minY + 8), size: 11, 0x111827)
            text("CA", at: CGPoint(x: CGFloat(width) - 210, y: bar.minY + 24), size: 11, 0x111827)
            text("⌁  ◖)", at: CGPoint(x: CGFloat(width) - 170, y: bar.minY + 15), size: 13, 0x111827)
            text("14:32", at: CGPoint(x: CGFloat(width) - 92, y: bar.minY + 8), size: 12, 0x111827)
            text("2026-11-05", at: CGPoint(x: CGFloat(width) - 106, y: bar.minY + 25), size: 12, 0x111827)
        }
    }

    // MARK: macOS (croquis : Mac mini)

    static func mac() -> RFBFramebuffer {
        let width = 1600, height = 900
        return render(width: width, height: height) { ctx in
            fill(ctx, CGRect(x: 0, y: 0, width: width, height: height), 0x2D3A4A)
            let gradient = CGGradient(colorsSpace: nil, colors: [color(0x2D3A4A), color(0x40536B)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: [])
            // Barre des menus.
            fill(ctx, CGRect(x: 0, y: 0, width: width, height: 28), 0xF5F5F7)
            ctx.setFillColor(color(0x111827)); ctx.fillEllipse(in: CGRect(x: 16, y: 8, width: 13, height: 13))
            var x: CGFloat = 46
            for (index, item) in ["Finder", "Fichier", "Édition", "Présentation", "Aller", "Fenêtre", "Aide"].enumerated() {
                text(item, at: CGPoint(x: x, y: 6), size: 13, 0x111827, weight: index == 0 ? .bold : .regular)
                x += CGFloat(item.count) * 8 + 22
            }
            text("jeu. 5 nov. 14:32", at: CGPoint(x: CGFloat(width) - 140, y: 6), size: 13, 0x111827)
            // Finder.
            let finder = CGRect(x: 60, y: 80, width: 830, height: 440)
            shadow(ctx, finder, radius: 12)
            fill(ctx, finder, 0xFFFFFF, radius: 12)
            fill(ctx, CGRect(x: finder.minX, y: finder.minY, width: 190, height: finder.height), 0xEEF0F3, radius: 12)
            fill(ctx, CGRect(x: finder.minX + 180, y: finder.minY, width: 10, height: finder.height), 0xEEF0F3)
            for (index, hex) in [0xEF4444, 0xF59E0B, 0x22C55E].enumerated() {
                ctx.setFillColor(color(UInt32(hex))); ctx.fillEllipse(in: CGRect(x: finder.minX + 16 + CGFloat(index) * 20, y: finder.minY + 16, width: 12, height: 12))
            }
            text("Favoris", at: CGPoint(x: finder.minX + 16, y: finder.minY + 50), size: 11, 0x6B7280, weight: .semibold)
            for (index, item) in ["Applications", "Bureau", "Documents", "Téléchargements"].enumerated() {
                let y = finder.minY + 74 + CGFloat(index) * 26
                if item == "Documents" { fill(ctx, CGRect(x: finder.minX + 8, y: y - 4, width: 170, height: 24), 0xD9DCE2, radius: 5) }
                text(item, at: CGPoint(x: finder.minX + 20, y: y), size: 13, 0x1F2937, weight: item == "Documents" ? .semibold : .regular)
            }
            text("Documents", at: CGPoint(x: finder.minX + 210, y: finder.minY + 16), size: 15, 0x111827, weight: .bold)
            let files: [(String, UInt32, Bool)] = [("Inventaire réseau.numbers", 0x22C55E, false), ("Plan baie.pdf", 0xEF4444, false),
                                                   ("Configs", 0x60A5FA, true), ("Captures", 0x60A5FA, true),
                                                   ("Rapport scan.pdf", 0xEF4444, false), ("Notes.txt", 0xE5E7EB, false)]
            for (index, file) in files.enumerated() {
                let column = index % 4, row = index / 4
                let cx = finder.minX + 270 + CGFloat(column) * 150, cy = finder.minY + 70 + CGFloat(row) * 140
                let icon = file.2 ? CGRect(x: cx - 34, y: cy + 12, width: 68, height: 52) : CGRect(x: cx - 28, y: cy, width: 56, height: 68)
                fill(ctx, icon, file.1, radius: file.2 ? 6 : 4)
                stroke(ctx, icon, 0xCBD5E1, radius: file.2 ? 6 : 4)
                centered(file.0.count > 20 ? String(file.0.prefix(18)) + "…" : file.0, in: CGRect(x: cx - 70, y: cy + 78, width: 140, height: 16), size: 12, 0x111827)
            }
            // Terminal.
            let terminal = CGRect(x: 820, y: 330, width: 700, height: 300)
            shadow(ctx, terminal, radius: 12)
            fill(ctx, terminal, 0x1C1C1E, radius: 12)
            fill(ctx, CGRect(x: terminal.minX, y: terminal.minY, width: terminal.width, height: 30), 0x2C2C2E, radius: 12)
            fill(ctx, CGRect(x: terminal.minX, y: terminal.minY + 20, width: terminal.width, height: 10), 0x2C2C2E)
            for (index, hex) in [0xEF4444, 0xF59E0B, 0x22C55E].enumerated() {
                ctx.setFillColor(color(UInt32(hex))); ctx.fillEllipse(in: CGRect(x: terminal.minX + 14 + CGFloat(index) * 20, y: terminal.minY + 9, width: 12, height: 12))
            }
            centered("dany — zsh — 80×24", in: CGRect(x: terminal.minX, y: terminal.minY + 7, width: terminal.width, height: 16), size: 12, 0xD1D5DB)
            let lines = ["dany@Macmini-de-Dany ~ % ping -c 2 10.182.122.1", "PING 10.182.122.1 (10.182.122.1): 56 data bytes",
                         "64 bytes from 10.182.122.1: icmp_seq=0 ttl=255 time=1.204 ms",
                         "64 bytes from 10.182.122.1: icmp_seq=1 ttl=255 time=0.982 ms", "", "dany@Macmini-de-Dany ~ % "]
            for (index, line) in lines.enumerated() {
                text(line, at: CGPoint(x: terminal.minX + 14, y: terminal.minY + 44 + CGFloat(index) * 20), size: 13, 0xE5E7EB, mono: true)
            }
            // Dock.
            let dockColors: [UInt32] = [0x3B82F6, 0xFFFFFF, 0x22C55E, 0x1C1C1E, 0xF59E0B]
            let dock = CGRect(x: CGFloat(width) / 2 - 190, y: CGFloat(height) - 78, width: 380, height: 68)
            fill(ctx, dock, 0xE5E7EB, alpha: 0.85, radius: 20)
            stroke(ctx, dock, 0xCBD5E1, radius: 20)
            for (index, hex) in dockColors.enumerated() {
                fill(ctx, CGRect(x: dock.minX + 14 + CGFloat(index) * 60, y: dock.minY + 9, width: 50, height: 50), hex, radius: 12)
            }
            fill(ctx, CGRect(x: dock.minX + 312, y: dock.minY + 14, width: 1, height: 40), 0x9CA3AF)
            fill(ctx, CGRect(x: dock.minX + 320, y: dock.minY + 9, width: 50, height: 50), 0x9CA3AF, radius: 12)
        }
    }
}
