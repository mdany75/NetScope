import Darwin
import Foundation
@testable import NetScopeCore

// Tests de la note 57 (terminal intégré d'Accès distant) : émulateur VT100/xterm sur des
// séquences fixes, clavier, journal, négociation Telnet, réglages série, commande ssh. Les
// liaisons réelles ne touchent que ce Mac : /bin/echo, /bin/cat et /bin/stty dans un
// pseudo-terminal, un faux serveur Telnet sur 127.0.0.1, une « console série » simulée par un
// pseudo-terminal. Aucun réseau, aucun port série réel.

/// Événements d'une liaison, relevés pour les tests.
final class TerminalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var connected = false
    private var closed: String??

    func handle(_ event: TerminalTransportEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .connected: connected = true
        case .data(let data): bytes += data
        case .closed(let message): closed = .some(message)
        }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    var data: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    /// nil : pas encore fermé ; .some(nil) : fin normale.
    var closure: String?? {
        lock.lock(); defer { lock.unlock() }
        return closed
    }
}

/// Attend qu'une condition devienne vraie (au plus `timeout` secondes).
func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Échoue si la condition n'est pas devenue vraie à temps.
func expectWait(_ condition: () -> Bool, _ message: String, timeout: TimeInterval = 5,
                file: String = #fileID, line: Int = #line) async throws {
    let ok = await waitFor(timeout, condition)
    try expect(ok, message, file: file, line: line)
}

func registerTerminalTests(_ suite: TestSuite) {
    let esc = "\u{1B}"

    // MARK: Émulateur

    suite.add("Terminal : texte, retour chariot et saut de ligne") {
        let term = TerminalEmulator(columns: 20, rows: 4)
        term.feed("Bonjour\r\nSW-CORE-01#")
        try expectEqual(term.screenLine(0).text, "Bonjour", "ligne 1")
        try expectEqual(term.screenLine(1).text, "SW-CORE-01#", "ligne 2")
        try expectEqual(term.cursorRow, 1, "curseur ligne")
        try expectEqual(term.cursorColumn, 11, "curseur colonne")
        term.feed("\rXY")
        try expectEqual(term.screenLine(1).text, "XY-CORE-01#", "retour chariot puis écrasement")
        term.feed("\u{8}\u{8}Z")
        try expectEqual(term.screenLine(1).text, "ZY-CORE-01#", "effacement arrière")
    }

    suite.add("Terminal : retour automatique et ligne exacte") {
        let term = TerminalEmulator(columns: 10, rows: 3)
        term.feed("0123456789")
        try expectEqual(term.cursorRow, 0, "10 caractères dans 10 colonnes : pas encore de nouvelle ligne")
        try expectEqual(term.cursorColumn, 9, "curseur sur la dernière colonne")
        term.feed("\r\n")
        try expectEqual(term.cursorRow, 1, "CR LF après une ligne pleine : une seule ligne")
        term.feed("abcdefghijKL")
        try expectEqual(term.screenLine(1).text, "abcdefghij", "ligne coupée")
        try expectEqual(term.screenLine(2).text, "KL", "suite sur la ligne suivante")
        try expect(term.screenLine(1).wrapped, "ligne marquée coupée")
        try expectEqual(term.text(from: TerminalPosition(line: 1, column: 0), to: TerminalPosition(line: 2, column: 10)),
                        "abcdefghijKL", "copie recollée")
        let noWrap = TerminalEmulator(columns: 5, rows: 2)
        noWrap.feed("\(esc)[?7labcdefg")
        try expectEqual(noWrap.screenLine(0).text, "abcdg", "sans retour automatique : la dernière colonne est écrasée")
    }

    suite.add("Terminal : déplacements du curseur et effacements") {
        let term = TerminalEmulator(columns: 10, rows: 5)
        term.feed("\(esc)[3;4HX")
        try expectEqual(term.screenLine(2).text, "   X", "CUP ligne 3 colonne 4")
        term.feed("\(esc)[2A\(esc)[2DY")
        try expectEqual(term.screenLine(0).text, "  Y", "CUU et CUB")
        term.feed("\(esc)[10;10HZ")
        try expectEqual(term.cursorRow, 4, "CUP borné à l'écran")
        term.feed("\(esc)[HAAAAAAAAAA\(esc)[1;5H\(esc)[K")
        try expectEqual(term.screenLine(0).text, "AAAA", "EL 0 : fin de ligne")
        term.feed("\(esc)[1;2H\(esc)[1K")
        try expectEqual(term.screenLine(0).text, "  AA", "EL 1 : début de ligne")
        term.feed("\(esc)[2J")
        try expectEqual(term.screenText.trimmingCharacters(in: .whitespacesAndNewlines), "", "ED 2 : écran effacé")
        term.feed("\(esc)[5G*\(esc)[3d+")
        try expectEqual(term.screenLine(2).text, "     +", "CHA et VPA")
        try expectEqual(term.screenLine(0).text, "    *", "CHA sur la ligne du curseur")
    }

    suite.add("Terminal : couleurs SGR 16, 256 et 24 bits") {
        let term = TerminalEmulator(columns: 20, rows: 2)
        term.feed("\(esc)[1;31mR\(esc)[0m\(esc)[92mV\(esc)[38;5;208mO\(esc)[48;2;10;20;30mB\(esc)[38:2::1:2:3mC\(esc)[7;4mI\(esc)[mN")
        let cells = term.screenLine(0).cells
        try expectEqual(cells[0].attributes.foreground, .indexed(1), "rouge")
        try expect(cells[0].attributes.flags.contains(.bold), "gras")
        try expectEqual(cells[1].attributes.foreground, .indexed(10), "vert vif (92)")
        try expect(!cells[1].attributes.flags.contains(.bold), "gras annulé par 0")
        try expectEqual(cells[2].attributes.foreground, .indexed(208), "256 couleurs")
        try expectEqual(cells[3].attributes.background, .rgb(10, 20, 30), "fond 24 bits")
        try expectEqual(cells[3].attributes.foreground, .indexed(208), "texte gardé")
        try expectEqual(cells[4].attributes.foreground, .rgb(1, 2, 3), "forme à deux-points")
        try expect(cells[5].attributes.flags.contains(.inverse) && cells[5].attributes.flags.contains(.underline), "inverse et souligné")
        try expectEqual(cells[6].attributes, .plain, "ESC [ m : tout annulé")
        term.feed("\(esc)[44m\(esc)[2K")
        try expectEqual(term.screenLine(0).cells[0].attributes.background, .indexed(4), "effacement avec la couleur de fond (BCE)")
    }

    suite.add("Terminal : région de défilement et historique") {
        let term = TerminalEmulator(columns: 10, rows: 4)
        term.feed("L1\r\nL2\r\nL3\r\nL4\r\nL5")
        try expectEqual(term.scrollback.count, 1, "une ligne passée dans l'historique")
        try expectEqual(term.line(at: 0).text, "L1", "ligne 1 dans l'historique")
        try expectEqual(term.screenLine(0).text, "L2", "haut de l'écran")
        // Région lignes 2 à 3 : seul ce bloc défile, sans rien envoyer à l'historique.
        term.feed("\(esc)[2;3r\(esc)[3;1H\nX")
        try expectEqual(term.screenLine(0).text, "L2", "au-dessus de la région : intact")
        try expectEqual(term.screenLine(1).text, "L4", "région décalée")
        try expectEqual(term.screenLine(2).text, "X", "nouvelle ligne en bas de la région")
        try expectEqual(term.screenLine(3).text, "L5", "sous la région : intact")
        try expectEqual(term.scrollback.count, 1, "historique inchangé")
        term.feed("\(esc)[2;1H\(esc)M")
        try expectEqual(term.screenLine(1).text, "", "RI en haut de la région : ligne vide insérée")
        try expectEqual(term.screenLine(2).text, "L4", "région décalée vers le bas")
    }

    suite.add("Terminal : historique limité (anneau)") {
        let term = TerminalEmulator(columns: 8, rows: 2, scrollbackLimit: 5)
        for n in 1...20 { term.feed("n\(n)\r\n") }
        try expectEqual(term.scrollback.count, 5, "5 lignes gardées")
        try expectEqual(term.line(at: 0).text, "n15", "plus ancienne ligne gardée")
        try expectEqual(term.line(at: 4).text, "n19", "plus récente")
        try expectEqual(term.scrollback.dropped, 14, "lignes retirées comptées")
        try expectEqual(TerminalEmulator.defaultScrollbackLimit, 10_000, "10 000 lignes par défaut")
        term.clearScrollback()
        try expectEqual(term.scrollback.count, 0, "⌘K : historique effacé")
    }

    suite.add("Terminal : écran alternatif (1049) et curseur sauvegardé") {
        let term = TerminalEmulator(columns: 10, rows: 3)
        term.feed("prompt$ ")
        term.feed("\(esc)[?1049h\(esc)[Hvi plein écran")
        try expect(term.isAlternateScreen, "écran alternatif")
        try expectEqual(term.totalLines, 3, "pas d'historique sur l'écran alternatif")
        try expectEqual(term.screenLine(0).text, "vi plein é", "contenu de l'application")
        term.feed("\(esc)[?1049l")
        try expect(!term.isAlternateScreen, "retour à l'écran principal")
        try expectEqual(term.screenLine(0).text, "prompt$", "écran principal restauré")
        try expectEqual(term.cursorColumn, 8, "curseur restauré")
        term.feed("\(esc)[2;5H\(esc)7\(esc)[H\(esc)8Z")
        try expectEqual(term.screenLine(1).text, "    Z", "DECSC et DECRC")
    }

    suite.add("Terminal : UTF-8 coupé, accents combinés, caractères larges") {
        let term = TerminalEmulator(columns: 10, rows: 2)
        let bytes = Array("é".utf8)
        term.feed([bytes[0]])
        term.feed([bytes[1]])
        term.feed("e\u{0301}漢x")
        let cells = term.screenLine(0).cells
        try expectEqual(cells[0].scalar, "é", "séquence UTF-8 coupée entre deux paquets")
        try expectEqual(cells[1].scalar, "é", "e + accent aigu composés")
        try expectEqual(cells[2].scalar, "漢", "idéogramme")
        try expectEqual(cells[2].width, 2, "largeur 2")
        try expect(cells[3].isContinuation, "cellule de continuation")
        try expectEqual(cells[4].scalar, "x", "suite après le caractère large")
        try expectEqual(term.screenLine(0).text, "éé漢x", "texte")
        term.feed([0xFF, 0x41])
        try expectEqual(term.screenLine(0).cells[5].scalar, "\u{FFFD}", "octet invalide remplacé")
        let latin = TerminalEmulator(columns: 10, rows: 1)
        latin.encoding = .latin1
        latin.feed([0x63, 0x61, 0x66, 0xE9])
        try expectEqual(latin.screenLine(0).text, "café", "ISO-8859-1")
        let ibm = TerminalEmulator(columns: 10, rows: 1)
        ibm.encoding = .cp437
        ibm.feed([0xC9, 0xCD, 0xBB])
        try expectEqual(ibm.screenLine(0).text, "╔═╗", "CP437")
        try expectEqual(TerminalCodePage.cp437.count, 128, "table CP437 complète")
        try expectEqual(TerminalEncoding.latin1.encode("é€"), [0xE9, UInt8(ascii: "?")], "saisie ISO-8859-1")
    }

    suite.add("Terminal : titre OSC, jeu graphique DEC, réponses au serveur") {
        let term = TerminalEmulator(columns: 10, rows: 3)
        term.feed("\(esc)]0;admin@nas: ~\u{7}")
        try expectEqual(term.title, "admin@nas: ~", "titre terminé par BEL")
        term.feed("\(esc)]2;SW-CORE-01\(esc)\\")
        try expectEqual(term.title, "SW-CORE-01", "titre terminé par ST")
        term.feed("\(esc)(0lqk\(esc)(B")
        try expectEqual(term.screenLine(0).text, "┌─┐", "graphismes DEC")
        term.feed("\(esc)[2;3H\(esc)[6n\(esc)[c")
        try expectEqual(String(decoding: term.takeResponses(), as: UTF8.self), "\(esc)[2;3R\(esc)[?62;22c", "position du curseur et identification")
        try expectEqual(term.takeResponses(), [], "réponses vidées")
        term.feed("\(esc)[18t")
        try expectEqual(String(decoding: term.takeResponses(), as: UTF8.self), "\(esc)[8;3;10t", "taille en caractères")
        term.feed("\(esc)[?1h\(esc)[?2004h\(esc)[?25l\(esc)[5 q")
        try expect(term.applicationCursorKeys && term.bracketedPaste && !term.cursorVisible, "modes DEC")
        try expectEqual(term.cursorStyle, .bar, "curseur en barre (DECSCUSR)")
        term.feed("\(esc)[!p")
        try expect(!term.applicationCursorKeys && term.cursorVisible, "DECSTR : modes remis")
        let dcs = TerminalEmulator(columns: 10, rows: 1)
        dcs.feed("a\(esc)P1$r0m\(esc)\\b\(esc)[?999hc")
        try expectEqual(dcs.screenLine(0).text, "abc", "chaîne DCS et mode inconnu ignorés")
    }

    suite.add("Terminal : insertion et suppression de caractères et de lignes") {
        let term = TerminalEmulator(columns: 8, rows: 4)
        term.feed("abcdef\(esc)[1;3H\(esc)[2@")
        try expectEqual(term.screenLine(0).text, "ab  cdef", "ICH")
        term.feed("\(esc)[3P")
        try expectEqual(term.screenLine(0).text, "abdef", "DCH")
        term.feed("\(esc)[1;1H\(esc)[2X")
        try expectEqual(term.screenLine(0).text, "  def", "ECH")
        term.feed("\(esc)[2;1HL2\r\nL3\r\nL4\(esc)[2;1H\(esc)[L")
        try expectEqual(term.screenLine(1).text, "", "IL : ligne insérée")
        try expectEqual(term.screenLine(2).text, "L2", "IL : décalage")
        try expectEqual(term.screenLine(3).text, "L3", "IL : L4 sortie en bas")
        term.feed("\(esc)[M")
        try expectEqual(term.screenLine(1).text, "L2", "DL")
        term.feed("\(esc)[4h\(esc)[2;1H>\(esc)[4l")
        try expectEqual(term.screenLine(1).text, ">L2", "mode insertion")
        term.feed("\(esc)[4;1HQ\(esc)[3b")
        try expectEqual(term.screenLine(3).text, "QQQQ", "REP : caractère répété")
    }

    suite.add("Terminal : redimensionnement et historique") {
        let term = TerminalEmulator(columns: 10, rows: 4)
        term.feed("A\r\nB\r\nC\r\nD")
        term.resize(columns: 6, rows: 2)
        try expectEqual(term.rows, 2, "lignes")
        try expectEqual(term.screenLine(0).text, "C", "haut de l'écran après réduction")
        try expectEqual(term.screenLine(1).text, "D", "ligne du curseur gardée")
        try expectEqual(term.scrollback.count, 2, "A et B passées dans l'historique")
        try expectEqual(term.cursorRow, 1, "curseur suivi")
        term.resize(columns: 12, rows: 4)
        try expectEqual(term.screenLine(0).text, "A", "lignes revenues de l'historique")
        try expectEqual(term.scrollback.count, 0, "historique vidé d'autant")
        try expectEqual(term.cursorRow, 3, "curseur toujours sur D")
        try expectEqual(term.screenLine(0).cells.count, 12, "largeur")
        let blank = TerminalEmulator(columns: 10, rows: 5)
        blank.feed("$ ")
        blank.resize(columns: 10, rows: 3)
        try expectEqual(blank.scrollback.count, 0, "lignes vides du bas retirées d'abord")
        try expectEqual(blank.screenLine(0).text, "$", "invite gardée en haut")
    }

    suite.add("Terminal : recherche, sélection de mot et copie") {
        let term = TerminalEmulator(columns: 40, rows: 3)
        term.feed("Gi1/0/22  WKS346  connected\r\nGi1/0/23  WKS341  notconnect\r\nÉcran")
        let matches = term.search("connect")
        try expectEqual(matches.count, 2, "deux résultats")
        try expectEqual(matches[0], TerminalMatch(line: 0, columns: 18..<25), "colonnes du premier")
        try expectEqual(term.search("ecran").first?.line, 2, "sans accents ni casse")
        try expectEqual(term.search("").count, 0, "recherche vide")
        let word = term.wordRange(at: TerminalPosition(line: 0, column: 3))
        try expectEqual(term.text(from: word.start, to: word.end), "Gi1/0/22", "nom d'interface entier")
        try expectEqual(term.text(from: TerminalPosition(line: 0, column: 10), to: TerminalPosition(line: 1, column: 16)),
                        "WKS346  connected\nGi1/0/23  WKS341", "copie sur deux lignes")
    }

    // MARK: Clavier et journal

    suite.add("Terminal : touches (flèches, Ctrl, Option comme Méta, touches de fonction)") {
        func s(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
        try expectEqual(s(TerminalKeyEncoder.encode(.up)), "\(esc)[A", "flèche")
        try expectEqual(s(TerminalKeyEncoder.encode(.up, applicationCursor: true)), "\(esc)OA", "flèche en mode application")
        try expectEqual(s(TerminalKeyEncoder.encode(.right, modifiers: [.control])), "\(esc)[1;5C", "Ctrl+flèche")
        try expectEqual(s(TerminalKeyEncoder.encode(.left, modifiers: [.option], optionAsMeta: true)), "\(esc)[1;3D", "Option+flèche (Méta)")
        try expectEqual(s(TerminalKeyEncoder.encode(.left, modifiers: [.option], optionAsMeta: false)), "\(esc)[D", "Option sans Méta : flèche simple")
        try expectEqual(TerminalKeyEncoder.encode(.character("c"), modifiers: [.control]), [3], "Ctrl-C")
        try expectEqual(TerminalKeyEncoder.encode(.character("Z"), modifiers: [.control]), [26], "Ctrl-Z")
        try expectEqual(TerminalKeyEncoder.encode(.character("["), modifiers: [.control]), [27], "Ctrl-[")
        try expectEqual(TerminalKeyEncoder.encode(.character(" "), modifiers: [.control]), [0], "Ctrl-espace")
        try expectEqual(s(TerminalKeyEncoder.encode(.character("b"), modifiers: [.option], optionAsMeta: true)), "\(esc)b", "Méta-b")
        try expectEqual(s(TerminalKeyEncoder.encode(.character("@"), modifiers: [.option], optionAsMeta: false)), "@", "Option compose @")
        try expectEqual(TerminalKeyEncoder.encode(.backspace), [0x7F], "effacement : DEL")
        try expectEqual(s(TerminalKeyEncoder.encode(.tab, modifiers: [.shift])), "\(esc)[Z", "Maj-Tab")
        try expectEqual(TerminalKeyEncoder.encode(.enter), [0x0D], "Entrée : CR")
        try expectEqual(s(TerminalKeyEncoder.encode(.function(1))), "\(esc)OP", "F1")
        try expectEqual(s(TerminalKeyEncoder.encode(.function(5))), "\(esc)[15~", "F5")
        try expectEqual(s(TerminalKeyEncoder.encode(.function(12), modifiers: [.shift])), "\(esc)[24;2~", "Maj-F12")
        try expectEqual(s(TerminalKeyEncoder.encode(.pageUp)), "\(esc)[5~", "Page précédente")
        try expectEqual(s(TerminalKeyEncoder.encode(.forwardDelete)), "\(esc)[3~", "Suppr")
        try expectEqual(s(TerminalKeyEncoder.encode(.home, applicationCursor: true)), "\(esc)OH", "Début en mode application")
        try expectEqual(s(TerminalKeyEncoder.paste("a\nb", bracketed: false)), "a\rb", "collage : LF → CR")
        try expectEqual(s(TerminalKeyEncoder.paste("x\(esc)[201~y", bracketed: true)), "\(esc)[200~xy\(esc)[201~", "collage encadré, fin forcée retirée")
    }

    suite.add("Terminal : journal de session en texte brut") {
        var filter = TerminalLogFilter()
        var log = filter.feed(Array("\(esc)[1;32mSW-CORE-01#\(esc)[0m show ver\r\n".utf8))
        log += filter.feed(Array("Cisco IOS XE\r\nabc\u{8}\u{8}XY\r\n\(esc)]0;titre\u{7}fin ".utf8))
        let bytes = Array("é\r\n".utf8)
        log += filter.feed([bytes[0]])
        log += filter.feed(Array(bytes[1...]))
        try expectEqual(log, "SW-CORE-01# show ver\nCisco IOS XE\naXY\nfin é\n", "séquences retirées, effacements appliqués, UTF-8 coupé")
        log = filter.feed(Array("progression 10 %\rprogression 99 %\(esc)[K".utf8))
        try expectEqual(log, "", "ligne pas encore terminée")
        try expectEqual(filter.pendingLine, "progression 99 %", "retour chariot : ligne réécrite")
    }

    // MARK: Telnet

    suite.add("Telnet : négociation ECHO, SGA, TTYPE, NAWS") {
        var telnet = TelnetNegotiator(columns: 132, rows: 40)
        try expectEqual(telnet.start(), [255, 253, 3, 255, 251, 24, 255, 251, 31], "ouverture : DO SGA, WILL TTYPE, WILL NAWS")
        // Le serveur : WILL ECHO, WILL SGA, DO TTYPE, DO NAWS, DO LINEMODE, puis du texte.
        var result = telnet.receive([255, 251, 1, 255, 251, 3, 255, 253, 24, 255, 253, 31, 255, 253, 34] + Array("Login: ".utf8))
        try expectEqual(String(decoding: result.data, as: UTF8.self), "Login: ", "commandes retirées du texte")
        try expectEqual(result.reply, [255, 253, 1, 255, 250, 31, 0, 132, 0, 40, 255, 240, 255, 252, 34],
                        "DO ECHO ; SGA, TTYPE déjà proposés ; taille ; LINEMODE refusé")
        try expect(telnet.remoteEcho, "écho du serveur")
        result = telnet.receive([255, 250, 24, 1, 255, 240])
        try expectEqual(result.reply, [255, 250, 24, 0] + Array("XTERM-256COLOR".utf8) + [255, 240], "TTYPE IS")
        try expectEqual(telnet.resize(columns: 255, rows: 50), [255, 250, 31, 0, 255, 255, 0, 50, 255, 240], "NAWS, 255 doublé")
        result = telnet.receive([255, 255, 65, 255, 252, 1])
        try expectEqual(result.data, [255, 65], "IAC IAC : octet 255 de données")
        try expectEqual(result.reply, [255, 254, 1], "WONT ECHO → DONT ECHO")
        try expect(!telnet.remoteEcho, "écho local de nouveau")
        try expectEqual(telnet.encodeOutgoing([0x0D, 0x41, 255]), [0x0D, 0x00, 0x41, 255, 255], "CR NUL et IAC doublé")
        try expectEqual(telnet.encodeOutgoing([0x0D, 0x0A]), [0x0D, 0x0A], "CR LF inchangé")
        // Commande coupée entre deux paquets.
        var split = TelnetNegotiator()
        _ = split.receive([255])
        result = split.receive([251, 1, 0x42])
        try expectEqual(result.reply, [255, 253, 1], "IAC coupé")
        try expectEqual(result.data, [0x42], "texte après la commande")
    }

    suite.add("Telnet : session réelle vers un faux serveur sur 127.0.0.1") {
        let received = ToolTestBox<[UInt8]>([])
        let server = try LocalTCPServer { fd in
            // Le serveur annonce l'écho, envoie une invite, puis lit la saisie.
            let hello: [UInt8] = [255, 251, 1, 255, 253, 31] + Array("User Access Verification\r\nUsername: ".utf8)
            _ = hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var buffer = [UInt8](repeating: 0, count: 256)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                received.mutate { $0 += buffer[0..<count] }
                if received.value.contains(0x0D) { break }
            }
        }
        defer { server.stop() }
        let recorder = TerminalRecorder()
        let transport = TelnetTransport(host: "127.0.0.1", port: Int(server.port), columns: 100, rows: 30, timeout: 3)
        transport.start { recorder.handle($0) }
        try await expectWait({ recorder.text.contains("Username: ") }, "invite reçue")
        try expect(!recorder.text.contains("\u{FF}"), "commandes Telnet retirées")
        try expect(!transport.wantsLocalEcho, "le serveur fait l'écho")
        transport.send(Array("admin\r".utf8))
        try await expectWait({ received.value.contains(0x0D) }, "saisie reçue par le serveur")
        let bytes = received.value
        try expect(bytes.starts(with: [255, 253, 3, 255, 251, 24, 255, 251, 31]), "propositions d'ouverture")
        try expect(bytes.contains(0x64) && bytes.suffix(7) == ArraySlice(Array("admin".utf8) + [0x0D, 0x00]), "saisie suivie de CR NUL")
        try await expectWait({ recorder.closure != nil }, "fin de session quand le serveur ferme")
    }

    suite.add("Telnet : port fermé sur 127.0.0.1 expliqué") {
        let port = try LocalTCPServer.unusedPort()
        let recorder = TerminalRecorder()
        let transport = TelnetTransport(host: "127.0.0.1", port: Int(port), timeout: 3)
        transport.start { recorder.handle($0) }
        try await expectWait({ recorder.closure != nil }, "échec signalé")
        let message = (recorder.closure ?? nil) ?? ""
        try expect(message.contains("refuse") || message.contains("Connexion impossible"), "message : \(message)")
    }

    // MARK: Série

    suite.add("Série : réglages termios (9600 8N1, 7E2, flux)") {
        var options = termios()
        SerialSettings.ciscoConsole.apply(to: &options)
        try expectEqual(cfgetospeed(&options), speed_t(9600), "9600 bauds")
        try expectEqual(options.c_cflag & tcflag_t(CSIZE), tcflag_t(CS8), "8 bits")
        try expect(options.c_cflag & tcflag_t(PARENB) == 0, "sans parité")
        try expect(options.c_cflag & tcflag_t(CSTOPB) == 0, "1 bit d'arrêt")
        try expect(options.c_cflag & tcflag_t(CRTSCTS) == 0 && options.c_iflag & tcflag_t(IXON) == 0, "sans contrôle de flux")
        try expect(options.c_lflag & tcflag_t(ECHO) == 0 && options.c_lflag & tcflag_t(ICANON) == 0, "mode brut")
        try expectEqual(SerialSettings.ciscoConsole.summary, "9600 8N1", "résumé Cisco/Fortinet")
        var other = termios()
        SerialSettings(baudRate: 115_200, dataBits: 7, parity: .even, stopBits: 2, flowControl: .rtsCts).apply(to: &other)
        try expectEqual(cfgetispeed(&other), speed_t(115_200), "115200 bauds")
        try expectEqual(other.c_cflag & tcflag_t(CSIZE), tcflag_t(CS7), "7 bits")
        try expect(other.c_cflag & tcflag_t(PARENB) != 0 && other.c_cflag & tcflag_t(PARODD) == 0, "parité paire")
        try expect(other.c_cflag & tcflag_t(CSTOPB) != 0, "2 bits d'arrêt")
        try expect(other.c_cflag & tcflag_t(CRTSCTS) != 0, "RTS/CTS")
        var soft = termios()
        SerialSettings(parity: .odd, flowControl: .xonXoff).apply(to: &soft)
        try expect(soft.c_cflag & tcflag_t(PARODD) != 0, "parité impaire")
        try expect(soft.c_iflag & tcflag_t(IXON) != 0 && soft.c_iflag & tcflag_t(IXOFF) != 0, "XON/XOFF")
        try expectThrows(SerialSettings.ValidationError.dataBits(9), "9 bits refusés") { _ = try SerialSettings(dataBits: 9).validated() }
        try expectEqual(SerialSettings(lineEnding: .crlf).enterBytes, [13, 10], "fin de ligne CR LF")
    }

    suite.add("Série : adaptateurs reconnus d'après le nom du port") {
        try expectEqual(SerialPortInfo(path: "/dev/cu.usbserial-A10K").adapter, "FTDI FT232 (USB-série)", "FTDI")
        try expectEqual(SerialPortInfo(path: "/dev/cu.SLAB_USBtoUART").adapter, "Silicon Labs CP210x (USB-série)", "CP210x")
        try expectEqual(SerialPortInfo(path: "/dev/cu.wchusbserial1420").adapter, "WCH CH340 (USB-série)", "CH340")
        try expect(SerialPortInfo(path: "/dev/cu.usbmodem14201").adapter.contains("CDC-ACM"), "console USB")
        try expect(SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port").adapter.contains("Bluetooth"), "Bluetooth")
        try expect(!SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port").isUSB, "Bluetooth pas USB")
        let ports = ["/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.usbserial-A10K", "/dev/cu.debug-console", "/dev/cu.SLAB_USBtoUART"]
            .map(SerialPortInfo.init(path:))
        try expectEqual(SerialPortInfo.sorted(ports).map(\.name),
                        ["cu.SLAB_USBtoUART", "cu.usbserial-A10K", "cu.Bluetooth-Incoming-Port", "cu.debug-console"],
                        "adaptateurs USB d'abord")
    }

    suite.add("Série : lecture et écriture sur un port simulé par un pseudo-terminal") {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw TestSkipped(reason: "pseudo-terminal indisponible") }
        defer { close(master); close(slave) }
        let recorder = TerminalRecorder()
        let transport = SerialTransport(path: String(cString: name), settings: .ciscoConsole)
        transport.start { recorder.handle($0) }
        try await expectWait({ recorder.isConnected }, "port ouvert")
        let boot = Array("Press RETURN to get started!\r\n".utf8)
        _ = boot.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
        try await expectWait({ recorder.text.contains("RETURN") }, "sortie de la console lue")
        transport.send([0x0D])
        var buffer = [UInt8](repeating: 0, count: 16)
        var got: [UInt8] = []
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        _ = await waitFor {
            let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if count > 0 { got += buffer[0..<count] }
            return got.contains(0x0D)
        }
        try expectEqual(got, [0x0D], "Entrée envoyée telle quelle (mode brut)")
        transport.close()
        try await expectWait({ recorder.closure != nil }, "port refermé")
    }

    // MARK: SSH

    suite.add("SSH intégré : arguments, environnement et script SSH_ASKPASS sans secret") {
        let args = SSHTerminalCommand.arguments(user: "netadmin", host: "10.182.122.2", port: 22)
        try expectEqual(Array(args.suffix(2)), ["--", "netadmin@10.182.122.2"], "destination après « -- »")
        try expect(args.contains("StrictHostKeyChecking=ask"), "serveur inconnu : demande dans l'onglet")
        try expect(!args.contains("-p"), "port 22 implicite")
        let custom = SSHTerminalCommand.arguments(user: "", host: "nas", port: 2222, keyPath: "~/.ssh/id_ed25519")
        try expect(custom.contains("-p") && custom.contains("2222"), "port personnalisé")
        try expectEqual(custom.last, "nas", "sans utilisateur")
        try expect(custom.contains((("~/.ssh/id_ed25519") as NSString).expandingTildeInPath), "clé choisie")
        let env = SSHTerminalCommand.environment(base: ["PATH": "/usr/bin", "TERM": "dumb", "SSH_ASKPASS": "/tmp/autre"],
                                                 askpass: "/tmp/nsterm/askpass.sh", secret: "s3cr3t!", flag: "/tmp/nsterm/x")
        try expectEqual(env["TERM"], "xterm-256color", "TERM")
        try expectEqual(env["SSH_ASKPASS"], "/tmp/nsterm/askpass.sh", "script de NetScope")
        try expectEqual(env["SSH_ASKPASS_REQUIRE"], "force", "toujours par le script")
        try expectEqual(env["NETSCOPE_SSH_SECRET"], "s3cr3t!", "secret dans l'environnement seulement")
        try expect(!args.joined().contains("s3cr3t") && !SSHTerminalCommand.askpassScript.contains("s3cr3t"), "jamais dans les arguments ni le script")
        try expectEqual(SSHTerminalCommand.environment(base: [:], askpass: "a", secret: nil, flag: "f")["NETSCOPE_SSH_SECRET"], nil, "sans secret")
        try expectEqual(SSHTerminalCommand.displayCommand(user: "admin", host: "10.0.0.2", port: 2222), "ssh -p 2222 -- admin@10.0.0.2", "commande affichée")
        try expectEqual(BackupKeychainScan.usage(for: "com.danymenard.netscope.acces"), "Mots de passe SSH et Telnet (Accès distant)",
                        "service du Trousseau nommé dans les sauvegardes")
    }

    suite.add("SSH intégré : le script SSH_ASKPASS donne le secret une seule fois") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-askpass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = try SSHTerminalCommand.writeAskpass(in: folder)
        let flag = folder.appendingPathComponent("drapeau").path
        func run(_ prompt: String, input: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, prompt]
            process.environment = ["NETSCOPE_SSH_SECRET": "motdepasse", "NETSCOPE_SSH_FLAG": flag, "PATH": "/usr/bin:/bin"]
            let output = Pipe(), stdin = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardInput = stdin
            process.standardError = errors
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        try expectEqual(try run("admin@10.0.0.2's password: ", input: "saisi\n"), "motdepasse\n", "première demande : Trousseau")
        try expect(FileManager.default.fileExists(atPath: flag), "fichier témoin créé")
        try expect(((try? String(contentsOfFile: flag, encoding: .utf8)) ?? "x").isEmpty, "fichier témoin vide (aucun secret)")
        try expectEqual(try run("admin@10.0.0.2's password: ", input: "saisi\n"), "saisi\n", "deuxième demande : saisie dans l'onglet")
        try expectEqual(try run("Are you sure you want to continue connecting (yes/no/[fingerprint])? ", input: "yes\n"), "yes\n",
                        "empreinte : réponse de l'utilisateur, jamais automatique")
        let mode = (try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.intValue
        try expectEqual(mode, 0o700, "script privé")
    }

    suite.add("SSH intégré : lecture des messages de ssh") {
        let unknown = """
        The authenticity of host '10.182.122.2 (10.182.122.2)' can't be established.
        ED25519 key fingerprint is SHA256:q3VtXyZ0abcdKvB5M.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?\u{20}
        """
        try expectEqual(SSHPromptDetector.scan(unknown), .unknownHost(fingerprint: "SHA256:q3VtXyZ0abcdKvB5M", keyType: "ED25519"), "serveur inconnu")
        try expectEqual(SSHPromptDetector.scan(unknown + "yes\nWarning: Permanently added '10.182.122.2'\n"), nil, "question déjà répondue")
        try expectEqual(SSHPromptDetector.scan("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @"), .hostKeyChanged, "clé changée")
        try expectEqual(SSHPromptDetector.scan("admin@10.0.0.2: Permission denied (publickey,password)."), .authenticationFailed, "refus")
        try expectEqual(SSHPromptDetector.scan("ssh: connect to host 10.0.0.9 port 22: Connection refused"), .connectionRefused, "port fermé")
        try expectEqual(SSHPromptDetector.scan("ssh: Could not resolve hostname nas: nodename nor servname provided"), .hostNotFound, "nom inconnu")
    }

    // MARK: Pseudo-terminal

    suite.add("Pseudo-terminal : /bin/echo, terminal de contrôle et taille") {
        let echo = TerminalRecorder()
        let process = PTYProcess(executable: "/bin/echo", arguments: ["Bonjour", "NetScope"], environment: ["PATH": "/usr/bin:/bin"])
        process.start { echo.handle($0) }
        try await expectWait({ echo.closure != nil }, "processus terminé")
        try expectEqual(echo.text, "Bonjour NetScope\r\n", "sortie avec CR LF du pseudo-terminal")
        try expectEqual(echo.closure ?? "x", nil, "fin normale (code 0)")

        let shell = TerminalRecorder()
        let check = PTYProcess(executable: "/bin/sh", arguments: ["-c", "test -t 0 && (: </dev/tty) && echo CTTY-OK; /bin/stty size; exit 3"],
                               environment: ["PATH": "/usr/bin:/bin"], columns: 132, rows: 40)
        check.start { shell.handle($0) }
        try await expectWait({ shell.closure != nil }, "shell terminé")
        try expect(shell.text.contains("CTTY-OK"), "le pseudo-terminal est le terminal de contrôle : \(shell.text)")
        try expect(shell.text.contains("40 132"), "taille transmise : \(shell.text)")
        try expectEqual(shell.closure ?? nil, "Session terminée (code 3).", "code de sortie expliqué")
    }

    suite.add("Pseudo-terminal : /bin/cat interactif, écho et redimensionnement") {
        let recorder = TerminalRecorder()
        let cat = PTYProcess(executable: "/bin/cat", arguments: [], environment: ["PATH": "/usr/bin:/bin"])
        cat.start { recorder.handle($0) }
        try await expectWait({ recorder.isConnected }, "lancé")
        cat.send(Array("réseau\r".utf8))
        // Le pseudo-terminal fait l'écho de la saisie, puis cat renvoie la ligne.
        try await expectWait({ recorder.text.components(separatedBy: "réseau").count >= 3 }, "écho et réponse : \(recorder.text)")
        cat.resize(columns: 100, rows: 30)
        cat.send([0x04])
        try await expectWait({ recorder.closure != nil }, "Ctrl-D : fin de cat")
        let emulator = TerminalEmulator(columns: 20, rows: 3)
        emulator.feed(recorder.data)
        try expectEqual(emulator.screenLine(0).text, "réseau", "écho dans l'émulateur")
        try expectEqual(emulator.screenLine(1).text, "réseau", "ligne renvoyée par cat")
        let sleeper = TerminalRecorder()
        let long = PTYProcess(executable: "/bin/sleep", arguments: ["30"], environment: [:])
        long.start { sleeper.handle($0) }
        try await expectWait({ sleeper.isConnected }, "sleep lancé")
        long.close()
        try await expectWait({ sleeper.closure != nil }, "fermeture de l’onglet : processus arrêté", timeout: 4)
        let missing = TerminalRecorder()
        PTYProcess(executable: "/nonexistent/ssh", arguments: [], environment: [:]).start { missing.handle($0) }
        try expect(((missing.closure ?? nil) ?? "").contains("Lancement de /nonexistent/ssh impossible"), "outil absent expliqué")
    }
}
