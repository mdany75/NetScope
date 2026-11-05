import Darwin
import Foundation
import NetScopeCore

// Tests du TFTP (note 51) : paquets, options, machines d'état (pures, données fixes) et, pour finir,
// un vrai serveur et un vrai client sur 127.0.0.1 seulement.

func registerTFTPTests(_ suite: TestSuite) {
    suite.add("TFTP : codage et décodage des paquets RRQ, WRQ, DATA, ACK, ERROR, OACK") {
        let rrq = TFTPPacket.request(TFTPRequest(kind: .read, filename: "SW-ETG2-01.cfg", mode: .octet,
                                                 options: [TFTPOption("blksize", "1468"), TFTPOption("tsize", "0")]))
        let bytes = rrq.encoded()
        try expectEqual(Array(bytes.prefix(2)), [0, 1], "opcode RRQ")
        try expectEqual(bytes, [0, 1] + Array("SW-ETG2-01.cfg".utf8) + [0] + Array("octet".utf8) + [0]
                        + Array("blksize".utf8) + [0] + Array("1468".utf8) + [0] + Array("tsize".utf8) + [0] + [0x30, 0],
                        "octets du RRQ")
        try expectEqual(try TFTPPacket.decode(bytes), rrq, "RRQ relu")
        let wrq = TFTPPacket.request(TFTPRequest(kind: .write, filename: "a.bin", mode: .netascii))
        try expectEqual(try TFTPPacket.decode(wrq.encoded()), wrq, "WRQ relu")
        // Mode en majuscules, options en majuscules : acceptés.
        let upper: [UInt8] = [0, 1] + Array("f".utf8) + [0] + Array("OCTET".utf8) + [0] + Array("BLKSIZE".utf8) + [0] + Array("8192".utf8) + [0]
        guard case .request(let parsed) = try TFTPPacket.decode(upper) else { throw TestFailure(message: "RRQ attendu", file: #fileID, line: #line) }
        try expectEqual(parsed.mode, .octet, "mode sans casse")
        try expectEqual(parsed.option("blksize"), "8192", "option sans casse")
        let data = TFTPPacket.data(block: 0xFFFF, payload: [1, 2, 3])
        try expectEqual(data.encoded(), [0, 3, 0xFF, 0xFF, 1, 2, 3], "DATA")
        try expectEqual(try TFTPPacket.decode(data.encoded()), data, "DATA relu")
        try expectEqual(TFTPPacket.ack(block: 258).encoded(), [0, 4, 1, 2], "ACK")
        let error = TFTPPacket.error(code: .fileNotFound, message: "Fichier introuvable")
        try expectEqual(try TFTPPacket.decode(error.encoded()), error, "ERROR relu")
        try expectEqual(try TFTPPacket.decode([0, 5, 0, 2]), .error(code: .accessViolation, message: ""), "ERROR sans message")
        let oack = TFTPPacket.oack([TFTPOption("blksize", "1468"), TFTPOption("tsize", "524288")])
        try expectEqual(try TFTPPacket.decode(oack.encoded()), oack, "OACK relu")
        try expectThrows(TFTPDecodeError.unknownOpcode(9), "opcode inconnu") { _ = try TFTPPacket.decode([0, 9, 0, 0]) }
        try expectThrows(TFTPDecodeError.tooShort, "trop court") { _ = try TFTPPacket.decode([0]) }
        try expectThrows(TFTPDecodeError.unsupportedMode("mail"), "mode mail refusé") {
            _ = try TFTPPacket.decode([0, 1] + Array("f".utf8) + [0] + Array("mail".utf8) + [0])
        }
        try expectThrows(TFTPDecodeError.malformed("chaîne sans zéro final"), "nom sans zéro") {
            _ = try TFTPPacket.decode([0, 1] + Array("f".utf8))
        }
    }

    suite.add("TFTP : négociation des options côté serveur (blksize, tsize, timeout, windowsize)") {
        let policy = TFTPServerPolicy(maxBlockSize: 8192, maxWindowSize: 8, timeout: 3, retries: 4)
        let read = TFTPRequest(kind: .read, filename: "fw.bin", options: [
            TFTPOption("blksize", "65464"), TFTPOption("tsize", "0"), TFTPOption("timeout", "5"),
            TFTPOption("windowsize", "32"), TFTPOption("multicast", ""),
        ])
        let (settings, oack) = TFTPNegotiation.server(read, policy: policy, fileSize: 18_874_368)
        try expectEqual(settings.blockSize, 8192, "blksize ramené au maximum du serveur")
        try expectEqual(settings.windowSize, 8, "windowsize ramené")
        try expectEqual(settings.timeout, 5, "timeout accepté")
        try expectEqual(settings.transferSize, 18_874_368, "tsize = taille du fichier")
        try expectEqual(oack, [TFTPOption("blksize", "8192"), TFTPOption("tsize", "18874368"), TFTPOption("timeout", "5"),
                               TFTPOption("windowsize", "8")], "OACK sans l’option inconnue")
        let invalid = TFTPRequest(kind: .write, filename: "x", options: [
            TFTPOption("blksize", "4"), TFTPOption("timeout", "0"), TFTPOption("tsize", "2048"), TFTPOption("windowsize", "abc"),
        ])
        let (written, writeOACK) = TFTPNegotiation.server(invalid, policy: policy, fileSize: nil)
        try expectEqual(written.blockSize, 512, "blksize trop petit ignoré")
        try expectEqual(written.timeout, 3, "timeout 0 ignoré")
        try expectEqual(written.transferSize, 2048, "tsize d’une écriture renvoyé")
        try expectEqual(writeOACK, [TFTPOption("tsize", "2048")], "seul tsize accepté")
        let plain = TFTPNegotiation.server(TFTPRequest(kind: .read, filename: "x"), policy: policy, fileSize: 10)
        try expect(plain.oack.isEmpty, "sans option : pas d’OACK (RFC 1350)")
    }

    suite.add("TFTP : options du client et contrôle de l’OACK") {
        let asked = TFTPNegotiation.clientOptions(blockSize: 1468, windowSize: 4, timeout: 3, transferSize: 0)
        try expectEqual(asked, [TFTPOption("blksize", "1468"), TFTPOption("timeout", "3"), TFTPOption("tsize", "0"),
                                TFTPOption("windowsize", "4")], "options demandées")
        let base = TFTPTransferSettings(blockSize: 1468, windowSize: 4, timeout: 3)
        let ok = TFTPNegotiation.client(oack: [TFTPOption("blksize", "1024"), TFTPOption("tsize", "4096")], requested: asked, base: base)
        guard case .success(let settings) = ok else { throw TestFailure(message: "OACK valide refusé", file: #fileID, line: #line) }
        try expectEqual(settings.blockSize, 1024, "blksize plus petit accepté")
        try expectEqual(settings.windowSize, 1, "fenêtre absente de l’OACK : 1")
        try expectEqual(settings.transferSize, 4096, "tsize lu")
        if case .success = TFTPNegotiation.client(oack: [TFTPOption("blksize", "2048")], requested: asked, base: base) {
            throw TestFailure(message: "blksize plus grand que demandé accepté", file: #fileID, line: #line)
        }
        if case .success = TFTPNegotiation.client(oack: [TFTPOption("multicast", "1")], requested: asked, base: base) {
            throw TestFailure(message: "option non demandée acceptée", file: #fileID, line: #line)
        }
    }

    suite.add("TFTP : émetteur, blocs, dernier bloc vide, ACK en double et retransmissions") {
        let file = Array((0..<1024).map { UInt8($0 % 251) })
        var offset = 0
        var sender = TFTPSender(settings: TFTPTransferSettings(blockSize: 512, retries: 2)) { count in
            let end = min(offset + count, file.count)
            defer { offset = end }
            return Array(file[offset..<end])
        }
        try expectEqual(sender.start(), .send([.data(block: 1, payload: Array(file[0..<512]))]), "bloc 1")
        try expectEqual(sender.receive(.ack(block: 1)), .send([.data(block: 2, payload: Array(file[512..<1024]))]), "bloc 2")
        try expectEqual(sender.receive(.ack(block: 1)), .send([]), "ACK en double ignoré (Sorcerer’s Apprentice)")
        try expectEqual(sender.timeout(), .send([.data(block: 2, payload: Array(file[512..<1024]))]), "retransmission au délai")
        // 1 024 octets = 2 blocs pleins : un bloc vide signale la fin.
        try expectEqual(sender.receive(.ack(block: 2)), .send([.data(block: 3, payload: [])]), "bloc vide final")
        try expectEqual(sender.receive(.ack(block: 3)), .complete([]), "fin")
        try expectEqual(sender.bytesAcknowledged, 1024, "octets acquittés")
        try expect(sender.isFinished, "terminé")

        var lost = TFTPSender(settings: TFTPTransferSettings(blockSize: 512, retries: 2)) { _ in [1, 2, 3] }
        _ = lost.start()
        _ = lost.timeout()
        _ = lost.timeout()
        try expectEqual(lost.timeout(), .fail(.timeout(retries: 2)), "abandon après 2 retransmissions")
        var refused = TFTPSender(settings: TFTPTransferSettings()) { _ in [] }
        _ = refused.start()
        let failure = refused.receive(.error(code: .diskFull, message: "flash full"))
        try expectEqual(failure, .fail(.remote(.diskFull, "flash full")), "ERROR de l’appareil")
        try expect(failure.packets.isEmpty, "pas de réponse à un ERROR")
    }

    suite.add("TFTP : OACK du serveur acquitté par ACK 0, puis fenêtre de 4 blocs (RFC 7440)") {
        let file = Array((0..<(8 * 9 + 3)).map { UInt8($0) })
        var offset = 0
        var sender = TFTPSender(settings: TFTPTransferSettings(blockSize: 8, windowSize: 4), oack: [TFTPOption("blksize", "8")]) { count in
            let end = min(offset + count, file.count)
            defer { offset = end }
            return Array(file[offset..<end])
        }
        try expectEqual(sender.start(), .send([.oack([TFTPOption("blksize", "8")])]), "OACK d’abord")
        try expectEqual(sender.timeout(), .send([.oack([TFTPOption("blksize", "8")])]), "OACK renvoyé au délai")
        guard case .send(let first) = sender.receive(.ack(block: 0)) else { throw TestFailure(message: "fenêtre attendue", file: #fileID, line: #line) }
        try expectEqual(first.count, 4, "4 blocs d’un coup")
        // ACK 2 : les blocs 3 et 4 sont renvoyés, puis 5 et 6 complètent la fenêtre.
        guard case .send(let second) = sender.receive(.ack(block: 2)) else { throw TestFailure(message: "suite attendue", file: #fileID, line: #line) }
        try expectEqual(second.map { packet -> UInt16 in if case .data(let block, _) = packet { return block }; return 0 }, [3, 4, 5, 6],
                        "reprise après le bloc 2")
    }

    suite.add("TFTP : récepteur, fenêtre, trou, bloc trop grand et ACK final renvoyé") {
        var received: [UInt8] = []
        let a: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8], b: [UInt8] = [9, 10, 11, 12, 13, 14, 15, 16], z = [UInt8](repeating: 0, count: 8)
        var receiver = TFTPReceiver(settings: TFTPTransferSettings(blockSize: 8, windowSize: 2), initial: .ack(block: 0)) { received += $0 }
        try expectEqual(receiver.start(), .send([.ack(block: 0)]), "ACK 0 (WRQ)")
        try expectEqual(receiver.receive(.data(block: 1, payload: a)), .send([]), "bloc 1 sans ACK (fenêtre de 2)")
        try expectEqual(receiver.receive(.data(block: 2, payload: b)), .send([.ack(block: 2)]), "ACK de fin de fenêtre")
        try expectEqual(receiver.receive(.data(block: 4, payload: z)), .send([.ack(block: 2)]), "trou : ACK du dernier bloc reçu")
        try expectEqual(receiver.receive(.data(block: 5, payload: z)), .send([]), "un seul ACK par trou")
        try expectEqual(receiver.timeout(), .send([.ack(block: 2)]), "délai : dernier ACK renvoyé")
        try expectEqual(receiver.receive(.data(block: 3, payload: [17])), .complete([.ack(block: 3)]), "dernier bloc court")
        try expectEqual(received, a + b + [17], "contenu")
        try expectEqual(receiver.receive(.data(block: 3, payload: [17])), .send([.ack(block: 3)]), "ACK final renvoyé")
        var big = TFTPReceiver(settings: TFTPTransferSettings(blockSize: 8), initial: nil) { _ in }
        if case .fail(.protocolError) = big.receive(.data(block: 1, payload: Array(repeating: 0, count: 9))) {} else {
            throw TestFailure(message: "bloc trop grand accepté", file: #fileID, line: #line)
        }
        var full = TFTPReceiver(settings: TFTPTransferSettings(blockSize: 8), initial: nil) { _ in
            throw TFTPFileError(.diskFull, "Disque plein")
        }
        let action = full.receive(.data(block: 1, payload: [1]))
        try expectEqual(action, .fail(.local(.diskFull, "Disque plein")), "erreur d’écriture")
        try expectEqual(action.packets, [.error(code: .diskFull, message: "Disque plein")], "ERROR 3 envoyé")
    }

    suite.add("TFTP : échange complet en mémoire avec pertes et retour à 0 des numéros de bloc") {
        // 70 000 blocs de 8 octets : les numéros dépassent 65 535 et repartent à 0.
        let size = 8 * 70_000 + 5
        var file = [UInt8](repeating: 0, count: size)
        for index in 0..<size { file[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
        for window in [1, 4] {
            var offset = 0
            var output: [UInt8] = []
            output.reserveCapacity(size)
            var sender = TFTPSender(settings: TFTPTransferSettings(blockSize: 8, windowSize: window, retries: 3)) { count in
                let end = min(offset + count, file.count)
                defer { offset = end }
                return Array(file[offset..<end])
            }
            var receiver = TFTPReceiver(settings: TFTPTransferSettings(blockSize: 8, windowSize: window, retries: 3), initial: nil) { output += $0 }
            var toReceiver: [TFTPPacket] = sender.start().packets
            var sent = 0
            var done = false
            var steps = 0
            while !done {
                steps += 1
                guard steps < 2_000_000 else { throw TestFailure(message: "échange sans fin", file: #fileID, line: #line) }
                if toReceiver.isEmpty {
                    // Rien n'est arrivé : délai côté émetteur.
                    let action = sender.timeout()
                    if case .fail(let failure) = action { throw TestFailure(message: "émetteur : \(failure)", file: #fileID, line: #line) }
                    toReceiver = action.packets
                    continue
                }
                var toSender: [TFTPPacket] = []
                for packet in toReceiver {
                    sent += 1
                    // Un paquet DATA sur 997 se perd.
                    if sent % 997 == 0 { continue }
                    let action = receiver.receive(packet)
                    if case .fail(let failure) = action { throw TestFailure(message: "récepteur : \(failure)", file: #fileID, line: #line) }
                    toSender += action.packets
                }
                toReceiver = []
                for (index, packet) in toSender.enumerated() {
                    // Un ACK sur 13 se perd aussi.
                    if (sent + index) % 13 == 0 { continue }
                    let action = sender.receive(packet)
                    if case .complete = action { done = true; break }
                    if case .fail(let failure) = action { throw TestFailure(message: "émetteur : \(failure)", file: #fileID, line: #line) }
                    toReceiver += action.packets
                }
                if done { break }
            }
            try expect(receiver.isFinished, "récepteur terminé (fenêtre \(window))")
            try expectEqual(output.count, file.count, "taille reçue (fenêtre \(window))")
            try expect(output == file, "contenu identique (fenêtre \(window))")
        }
    }

    suite.add("TFTP : client — OACK, serveur sans options, ERROR 8 puis nouvelle requête sans options") {
        var got: [UInt8] = []
        let options = TFTPNegotiation.clientOptions(blockSize: 1468, windowSize: 1, timeout: 3, transferSize: 0)
        var get = TFTPClientMachine(get: "phone.cfg", options: options, settings: TFTPTransferSettings(blockSize: 1468)) { got += $0 }
        try expectEqual(get.start(), .send([.request(TFTPRequest(kind: .read, filename: "phone.cfg", options: options))]), "RRQ avec options")
        try expectEqual(get.receive(.oack([TFTPOption("blksize", "1468"), TFTPOption("tsize", "3")])), .send([.ack(block: 0)]), "ACK 0 après l’OACK")
        try expectEqual(get.phase, .transferring, "transfert lancé")
        try expectEqual(get.receive(.data(block: 1, payload: [7, 8, 9])), .complete([.ack(block: 1)]), "fin")
        try expectEqual(got, [7, 8, 9], "contenu")

        var plain = TFTPClientMachine(get: "old.cfg", options: options, settings: TFTPTransferSettings(blockSize: 1468)) { _ in }
        _ = plain.start()
        try expectEqual(plain.receive(.data(block: 1, payload: Array(repeating: 1, count: 512))), .send([.ack(block: 1)]),
                        "serveur RFC 1350 : blocs de 512")
        try expectEqual(plain.settings.blockSize, 512, "blksize par défaut")

        var refused = TFTPClientMachine(put: "fw.bin", options: options, settings: TFTPTransferSettings(blockSize: 1468)) { _ in [] }
        _ = refused.start()
        try expectEqual(refused.receive(.error(code: .optionRefused, message: "")),
                        .send([.request(TFTPRequest(kind: .write, filename: "fw.bin", options: []))]), "WRQ sans options")
        try expect(refused.fellBackWithoutOptions, "repli noté")
        try expectEqual(refused.receive(.ack(block: 0)), .send([.data(block: 1, payload: [])]), "ACK 0 : premier bloc")
        try expectEqual(refused.receive(.ack(block: 1)), .complete([]), "fichier vide envoyé")

        var silent = TFTPClientMachine(get: "x", options: [], settings: TFTPTransferSettings(retries: 1)) { _ in }
        _ = silent.start()
        try expectEqual(silent.timeout(), .send([.request(TFTPRequest(kind: .read, filename: "x"))]), "requête renvoyée")
        try expectEqual(silent.timeout(), .fail(.timeout(retries: 1)), "abandon")
        var missing = TFTPClientMachine(get: "x", options: [], settings: TFTPTransferSettings()) { _ in }
        _ = missing.start()
        try expectEqual(missing.receive(.error(code: .fileNotFound, message: "File not found")),
                        .fail(.remote(.fileNotFound, "File not found")), "fichier introuvable sur l’appareil")
    }

    suite.add("TFTP : chemins limités au dossier partagé (pas de « ../ »)") {
        try expectEqual(TFTPPath.components(of: "/config.txt"), ["config.txt"], "barre de tête ignorée")
        try expectEqual(TFTPPath.components(of: "firmware\\9300\\image.bin"), ["firmware", "9300", "image.bin"], "barres inverses")
        try expectEqual(TFTPPath.components(of: "./a//b/./c"), ["a", "b", "c"], "« . » et barres doubles")
        try expect(TFTPPath.components(of: "../etc/passwd") == nil, "« .. » refusé")
        try expect(TFTPPath.components(of: "a/../../b") == nil, "« .. » au milieu refusé")
        try expect(TFTPPath.components(of: "..\\..\\x") == nil, "« ..\\ » refusé")
        try expect(TFTPPath.components(of: "a\u{0}b") == nil, "caractère nul refusé")
        try expect(TFTPPath.components(of: "/") == nil, "racine seule refusée")
        try expect(TFTPPath.components(of: "") == nil, "nom vide refusé")
    }

    suite.add("TFTP : fichiers du partage — lecture seule, écrasement, lien hors du dossier, netascii") {
        let root = try tftpTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("hostname SW-ETG2-01\n".utf8).write(to: root.appendingPathComponent("sw.cfg"))
        let outside = root.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("lien.txt"), withDestinationURL: outside)
        let readOnly = TFTPFileAccess(root: root)
        try expectThrows(TFTPFileError(.accessViolation, "Écriture refusée\u{00A0}: le serveur est en lecture seule."), "lecture seule") {
            _ = try readOnly.openForWriting("new.cfg", mode: .octet, announcedSize: nil)
        }
        do {
            _ = try readOnly.openForReading("lien.txt", mode: .octet)
            throw TestFailure(message: "lien hors du partage lu", file: #fileID, line: #line)
        } catch let error as TFTPFileError {
            try expectEqual(error.code, .accessViolation, "lien refusé")
        }
        do {
            _ = try readOnly.openForReading("absent.bin", mode: .octet)
            throw TestFailure(message: "fichier absent ouvert", file: #fileID, line: #line)
        } catch let error as TFTPFileError {
            try expectEqual(error.code, .fileNotFound, "fichier introuvable")
        }
        let writable = TFTPFileAccess(root: root, allowWrite: true)
        do {
            _ = try writable.openForWriting("sw.cfg", mode: .octet, announcedSize: nil)
            throw TestFailure(message: "écrasement permis", file: #fileID, line: #line)
        } catch let error as TFTPFileError {
            try expectEqual(error.code, .fileExists, "écrasement refusé par défaut")
        }
        let overwrite = TFTPFileAccess(root: root, allowWrite: true, allowOverwrite: true)
        let sink = try overwrite.openForWriting("sw.cfg", mode: .netascii, announcedSize: nil)
        // « a CR LF b CR NUL c » coupé au milieu d'une paire.
        try sink.write([0x61, 0x0D])
        try sink.write([0x0A, 0x62, 0x0D])
        try sink.write([0x00, 0x63])
        try sink.commit()
        try expectEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("sw.cfg"))), [0x61, 0x0A, 0x62, 0x0D, 0x63], "netascii décodé")
        let source = try readOnly.openForReading("sw.cfg", mode: .netascii)
        try expectEqual(source.size, 7, "taille netascii (LF → CR LF, CR → CR NUL)")
        try expectEqual(try source.read(100), [0x61, 0x0D, 0x0A, 0x62, 0x0D, 0x00, 0x63], "netascii encodé")
        let names = readOnly.listing().map(\.path)
        try expect(names.contains("sw.cfg"), "liste du partage")
        try expect(!names.contains(where: { $0.contains("tftp-partiel") }), "aucun fichier partiel restant")
        let partial = try overwrite.openForWriting("partiel.bin", mode: .octet, announcedSize: nil)
        try partial.write([1, 2, 3])
        partial.discard()
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("partiel.bin").path), "transfert interrompu : rien n’est laissé")
        let small = TFTPFileAccess(root: root, allowWrite: true, maxWriteSize: 10)
        do {
            _ = try small.openForWriting("gros.bin", mode: .octet, announcedSize: 11)
            throw TestFailure(message: "fichier trop gros accepté", file: #fileID, line: #line)
        } catch let error as TFTPFileError {
            try expectEqual(error.code, .diskFull, "taille maximale")
        }
    }

    suite.add("TFTP : serveur et client sur 127.0.0.1 (get, put, options, erreurs)") {
        let root = try tftpTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var firmware = [UInt8](repeating: 0, count: 300_000)
        for index in firmware.indices { firmware[index] = UInt8(truncatingIfNeeded: index &* 13 &+ index >> 8) }
        try Data(firmware).write(to: root.appendingPathComponent("fw.bin"))
        let events = TFTPEventLog()
        let localhost = IPv4Address(127, 0, 0, 1)
        let server = TFTPServer(configuration: TFTPServer.Configuration(root: root, port: 0, listenAddress: localhost, allowWrite: true,
                                                                       policy: TFTPServerPolicy(maxBlockSize: 8192, maxWindowSize: 8, timeout: 1, retries: 3))) {
            events.append($0)
        }
        try server.start()
        defer { server.stop() }
        let port = server.boundPort
        try expect(port != 0, "port obtenu")
        let downloads = try tftpTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: downloads.deletingLastPathComponent()) }

        // get avec options (blksize 1468, fenêtre 4).
        let target = downloads.appendingPathComponent("fw-recu.bin")
        let result = try await TFTPClient.transfer(.get, host: localhost, port: port, remote: "/fw.bin", local: target,
                                                   options: TFTPClient.Options(blockSize: 1468, windowSize: 4, timeout: 1, retries: 3))
        try expectEqual(result.bytes, Int64(firmware.count), "octets reçus")
        try expectEqual(result.settings.blockSize, 1468, "blksize négocié")
        try expectEqual(result.settings.windowSize, 4, "fenêtre négociée")
        try expect(!result.withoutOptions, "options acceptées")
        let gotGet = [UInt8](try Data(contentsOf: target))
        try expect(gotGet == firmware, "fichier identique (get)")

        // get sans options (RFC 1350 pure).
        let plainTarget = downloads.appendingPathComponent("fw-plain.bin")
        let plain = try await TFTPClient.transfer(.get, host: localhost, port: port, remote: "fw.bin", local: plainTarget,
                                                  options: TFTPClient.Options(timeout: 1, retries: 3, useOptions: false))
        try expectEqual(plain.settings.blockSize, 512, "blocs de 512")
        let gotPlain = [UInt8](try Data(contentsOf: plainTarget))
        try expect(gotPlain == firmware, "fichier identique (RFC 1350)")

        // put : le fichier arrive dans le partage.
        let config = downloads.appendingPathComponent("backup.cfg")
        try Data("interface 1/1\n vlan 20\n".utf8).write(to: config)
        let put = try await TFTPClient.transfer(.put, host: localhost, port: port, remote: "sauvegardes-sw.cfg", local: config,
                                                options: TFTPClient.Options(blockSize: 512, timeout: 1, retries: 3))
        try expectEqual(put.bytes, 23, "octets envoyés")
        try expectEqual(try Data(contentsOf: root.appendingPathComponent("sauvegardes-sw.cfg")), try Data(contentsOf: config), "fichier écrit (put)")

        // Erreurs en clair.
        do {
            _ = try await TFTPClient.transfer(.get, host: localhost, port: port, remote: "absent.bin",
                                              local: downloads.appendingPathComponent("x"), options: TFTPClient.Options(timeout: 1, retries: 2))
            throw TestFailure(message: "fichier absent reçu", file: #fileID, line: #line)
        } catch let failure as TFTPFailure {
            guard case .remote(.fileNotFound, _) = failure else { throw TestFailure(message: "attendu : introuvable, obtenu \(failure)", file: #fileID, line: #line) }
        }
        try expect(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent("x").path), "rien d’enregistré après un échec")
        do {
            _ = try await TFTPClient.transfer(.get, host: localhost, port: port, remote: "../secret",
                                              local: downloads.appendingPathComponent("y"), options: TFTPClient.Options(timeout: 1, retries: 2))
            throw TestFailure(message: "« ../ » servi", file: #fileID, line: #line)
        } catch let failure as TFTPFailure {
            guard case .remote(.accessViolation, _) = failure else { throw TestFailure(message: "attendu : accès refusé, obtenu \(failure)", file: #fileID, line: #line) }
        }
        do {
            _ = try await TFTPClient.transfer(.put, host: localhost, port: port, remote: "fw.bin", local: config,
                                              options: TFTPClient.Options(timeout: 1, retries: 2))
            throw TestFailure(message: "fichier existant écrasé", file: #fileID, line: #line)
        } catch let failure as TFTPFailure {
            guard case .remote(.fileExists, _) = failure else { throw TestFailure(message: "attendu : existe déjà, obtenu \(failure)", file: #fileID, line: #line) }
        }
        let intact = [UInt8](try Data(contentsOf: root.appendingPathComponent("fw.bin")))
        try expect(intact == firmware, "fichier existant intact")

        // Journal du serveur : 3 transferts réussis, 3 refus.
        try await Task.sleep(nanoseconds: 200_000_000)
        try expectEqual(events.finished, 3, "transferts réussis notés")
        try expectEqual(events.refused, 3, "refus notés")
    }

    suite.add("TFTP : délai dépassé quand personne ne répond (127.0.0.1, port fermé)") {
        // Port local sans serveur : ICMP « port fermé » ou délai, jamais un succès.
        let (closedPort, fd) = try tftpReservedPort()
        close(fd)
        let started = Date()
        do {
            _ = try await TFTPClient.transfer(.get, host: IPv4Address(127, 0, 0, 1), port: closedPort, remote: "x",
                                              local: try tftpTemporaryFolder().appendingPathComponent("x"),
                                              options: TFTPClient.Options(timeout: 1, retries: 1))
            throw TestFailure(message: "transfert sans serveur réussi", file: #fileID, line: #line)
        } catch is TFTPFailure {
            try expect(Date().timeIntervalSince(started) < 5, "abandon rapide")
        }
    }

    suite.add("TFTP : coupe-feu, arrêt automatique, historique par site, mise en forme") {
        let on = TFTPFirewallStatus.parse(globalState: "Firewall is enabled. (State = 1)",
                                          blockAll: "Firewall has block all state set to disabled.",
                                          app: "Incoming connection to /Applications/NetScope.app is permitted.")
        try expectEqual(on, TFTPFirewallStatus(enabled: true, blockAll: false, app: .allowed), "coupe-feu actif, app permise")
        try expect(on.warning == nil, "pas d’avertissement")
        let blocked = TFTPFirewallStatus.parse(globalState: "Firewall is enabled. (State = 1)", blockAll: "Firewall has block all state set to enabled.", app: "")
        try expect(blocked.blockAll && blocked.warning != nil, "tout bloqué : avertissement")
        let off = TFTPFirewallStatus.parse(globalState: "Firewall is disabled. (State = 0)", blockAll: "", app: "")
        try expect(!off.enabled && off.warning == nil, "coupe-feu inactif")
        let unknown = TFTPFirewallStatus.parse(globalState: "Firewall is enabled. (State = 1)", blockAll: "", app: "The application is not part of the firewall")
        try expectEqual(unknown.app, .unknown, "app inconnue du coupe-feu")
        try expect(unknown.warning?.contains("Autoriser") == true, "macOS demandera")

        let now = Date()
        try expectEqual(TFTPAutoStop.remaining(lastActivity: now.addingTimeInterval(-60), delay: 900, activeTransfers: 0, now: now), 840, "14 min restantes")
        try expectEqual(TFTPAutoStop.remaining(lastActivity: now.addingTimeInterval(-1000), delay: 900, activeTransfers: 0, now: now), 0, "arrêt")
        try expectEqual(TFTPAutoStop.remaining(lastActivity: now.addingTimeInterval(-1000), delay: 900, activeTransfers: 1, now: now), 900,
                        "jamais pendant un transfert")
        try expect(TFTPAutoStop.remaining(lastActivity: now, delay: nil, activeTransfers: 0) == nil, "jamais")
        try expectEqual(TFTPAutoStop.text(845), "14\u{00A0}min\u{00A0}05\u{00A0}s", "texte du compte à rebours")

        var list: [TFTPTransferRecord] = []
        let a = TFTPTransferRecord(role: .server, flow: .toDevice, peer: "10.182.122.121", filename: "y.cfg", site: "bureau")
        list = TFTPHistory.upsert(a, into: list)
        list = TFTPHistory.upsert(TFTPTransferRecord(role: .client, flow: .fromDevice, peer: "10.0.0.2", filename: "z", site: "entrepot"), into: list)
        var done = a
        done.status = .done
        done.bytes = 2048
        list = TFTPHistory.upsert(done, into: list)
        try expectEqual(list.count, 2, "remplacement par identifiant")
        try expectEqual(TFTPHistory.forSite("bureau", in: list).map(\.status), [.done], "historique du site")
        let reopened = TFTPHistory.closingInterrupted([TFTPTransferRecord(role: .server, flow: .toDevice, peer: "x", filename: "f")])
        try expectEqual(reopened.first?.status, .cancelled, "transfert interrompu à la relecture")
        try expectEqual(TFTPFormat.bytes(512), "512\u{00A0}o", "octets")
        try expectEqual(TFTPFormat.bytes(18_874_368), "18,0\u{00A0}Mio", "Mio")
        try expectEqual(TFTPFormat.rate(bytes: 2_097_152, seconds: 2), "1,0\u{00A0}Mio/s", "débit")
        try expectEqual(TFTPFormat.percent(50, of: 200), "25\u{00A0}%", "pourcentage")
        try expectEqual(TFTPServer.bindAddress(port: 69, listen: IPv4Address("10.182.122.135")), nil, "port 69 : toutes les interfaces, filtrées")
        try expectEqual(TFTPServer.bindAddress(port: 6969, listen: IPv4Address("10.182.122.135")), IPv4Address("10.182.122.135"), "port > 1024 : l’adresse choisie")
    }
}

/// Dossier temporaire neuf (dans un dossier parent à supprimer).
private func tftpTemporaryFolder() throws -> URL {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("netscope-tftp-\(UUID().uuidString)")
    let root = parent.appendingPathComponent("partage")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Chemin réel (/private/var/…) : les comparaisons de liens se font sur des chemins résolus.
    return root.resolvingSymlinksInPath()
}

/// Port UDP libre sur 127.0.0.1 (le socket est rendu pour être fermé).
private func tftpReservedPort() throws -> (UInt16, Int32) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return (UInt16(bigEndian: addr.sin_port), fd)
}

/// Événements du serveur, comptés depuis ses fils d'exécution.
private final class TFTPEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TFTPServer.Event] = []

    func append(_ event: TFTPServer.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var finished: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { if case .finished = $0 { return true }; return false }.count
    }

    var refused: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { if case .refused = $0 { return true }; return false }.count
    }
}
