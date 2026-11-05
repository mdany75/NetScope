import Foundation
import NetScopeCore

// Note 78 : XMODEM et YMODEM de la console série. Calculs sur des valeurs connues, puis l'émetteur
// et le récepteur de NetScope reliés par un tuyau simulé (aucun port série) : blocs abîmés, perdus,
// coupés, ACK perdus, bruit sur la ligne, annulation et délais, avec une horloge simulée.

func registerSerialFileTransferTests(_ suite: TestSuite) {
    suite.add("XMODEM : CRC-16, somme, blocs, en-tête YMODEM et noms reçus") {
        try expectEqual(XModem.crc16(Array("123456789".utf8)), 0x31C3, "CRC-16/XMODEM de « 123456789 »")
        try expectEqual(XModem.crc16([]), 0, "CRC vide")
        try expectEqual(XModem.checksum([0xFF, 0x02][...]), 0x01, "somme sur 8 bits")
        let small = XModem.block(number: 1, payload: [0x41, 0x42][...], size: 128, crc: false)
        try expectEqual(small.count, 132, "bloc de 128 avec somme")
        try expectEqual(Array(small.prefix(3)), [0x01, 0x01, 0xFE], "SOH, numéro, complément")
        try expectEqual(small[5], 0x1A, "bourrage CP/M")
        try expectEqual(small.last, XModem.checksum(small[3..<131]), "somme du bloc")
        let large = XModem.block(number: 255, payload: [][...], size: 1_024, crc: true)
        try expectEqual(large.count, 1_029, "bloc de 1 Kio avec CRC")
        try expectEqual(Array(large.prefix(3)), [0x02, 0xFF, 0x00], "STX, 255, 0")
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let header = XModem.ymodemHeader(SerialFile(name: "c9200-rommon.pkg", data: [UInt8](repeating: 1, count: 4_242), modified: date))
        try expectEqual(header.count, 133, "en-tête de 128 octets avec CRC")
        try expectEqual(Array(header.prefix(3)), [0x01, 0x00, 0xFF], "bloc 0")
        let parsed = XModem.parseHeader(Array(header[3..<131]))
        try expectEqual(parsed.name, "c9200-rommon.pkg", "nom relu")
        try expectEqual(parsed.size, 4_242, "taille relue")
        try expectEqual(parsed.modified, date, "date relue (octal)")
        try expectEqual(XModem.parseHeader(Array(XModem.ymodemHeader(nil)[3..<131])).name, "", "bloc 0 vide : fin du lot")
        let long = XModem.ymodemHeader(SerialFile(name: String(repeating: "n", count: 150), data: []))
        try expectEqual(long.count, 1_029, "nom long : en-tête de 1 Kio")
        try expectEqual(XModem.safeName("../../etc/passwd"), "passwd", "pas de remontée de dossier")
        try expectEqual(XModem.safeName(".."), "fichier-recu.bin", "nom vide remplacé")
        try expectEqual(XModem.safeName("a\u{07}b:c.bin"), "abc.bin", "caractères de contrôle retirés")
        try expectEqual(XModem.safeName(".zshrc"), "zshrc", "pas de fichier caché")
        try expectEqual(XModem.safeName("..."), "fichier-recu.bin", "que des points : nom de repli")
        try expectEqual(XModem.cancelSequence.prefix(8).allSatisfy { $0 == 0x18 }, true, "huit CAN")
    }

    suite.add("XMODEM : envoi et réception sur un tuyau propre (somme, CRC, 1 Kio, numéros au-delà de 255)") {
        let file = SerialFile(name: "c2960-lanbasek9.bin", data: pattern(40_123))
        for (sendProto, receiveProto, expectCRC) in [(SerialFileProtocol.xmodem, SerialFileProtocol.xmodem, false),
                                                     (.xmodem, .xmodemCRC, true), (.xmodem1K, .xmodem1K, true)] {
            let sender = XModemSender(proto: sendProto, files: [file])
            let receiver = XModemReceiver(proto: receiveProto, defaultName: "recu.bin")
            let link = SerialLink(sender: sender, receiver: receiver)
            try link.run()
            try expectEqual(sender.state, .finished, "\(sendProto) → \(receiveProto) : émetteur")
            try expectEqual(receiver.state, .finished, "\(sendProto) → \(receiveProto) : récepteur")
            try expectEqual(receiver.receivedFiles.first?.data, file.data, "\(receiveProto) : fichier identique (bourrage retiré)")
            try expectEqual(sender.progress.useCRC, expectCRC, "\(receiveProto) : contrôle choisi par le récepteur")
            try expectEqual(sender.progress.retries, 0, "aucune reprise")
            try expectEqual(sender.progress.bytes, Int64(file.data.count), "avancement complet")
        }
        // XMODEM-1K : le récepteur demande la somme (vieux chargeur) → l'émetteur revient à 128 octets.
        let sender = XModemSender(proto: .xmodem1K, files: [file])
        let receiver = XModemReceiver(proto: .xmodem)
        try SerialLink(sender: sender, receiver: receiver).run()
        try expectEqual(receiver.receivedFiles.first?.data, file.data, "1 Kio replié en 128 octets avec somme")
        try expectEqual(sender.progress.blockSize, 128, "blocs de 128 octets")
    }

    suite.add("XMODEM-CRC : un « C » de démarrage en retard ne fait pas renvoyer le bloc 1") {
        let file = SerialFile(name: "config.txt", data: pattern(300))
        let sender = XModemSender(proto: .xmodemCRC, files: [file])
        let first = sender.receive([XModemByte.crcRequest], now: 0)
        try expect(!first.isEmpty, "bloc 1 envoyé sur le premier « C »")
        try expectEqual(sender.receive([XModemByte.crcRequest], now: 0.1), [], "second « C » ignoré en attente de l’ACK")
        let second = sender.receive([XModemByte.ack], now: 0.2)
        try expect(!second.isEmpty && second[1] == 2, "l’ACK fait partir le bloc 2")
    }

    suite.add("XMODEM : blocs abîmés, perdus, coupés, ACK perdus et bruit — reprises jusqu’au fichier exact") {
        let file = SerialFile(name: "firmware.bin", data: pattern(9_000))
        for proto in [SerialFileProtocol.xmodem, .xmodemCRC, .xmodem1K] {
            let sender = XModemSender(proto: proto, files: [file])
            let receiver = XModemReceiver(proto: proto)
            let link = SerialLink(sender: sender, receiver: receiver)
            // Émetteur → récepteur : bloc 3 abîmé, bloc 5 perdu, bloc 7 coupé, bruit avant le bloc 2.
            link.toReceiver = { index, bytes in
                switch index {
                case 2: return Array("\r\nrommon 1 > ".utf8) + bytes
                case 3: var copy = bytes; copy[40] ^= 0x5A; return copy
                case 5: return nil
                case 7: return Array(bytes.prefix(60))
                default: return bytes
                }
            }
            // Récepteur → émetteur : le 4e ACK se perd (bloc reçu deux fois).
            link.toSender = { index, bytes in index == 4 ? nil : bytes }
            try link.run()
            try expectEqual(receiver.state, .finished, "\(proto) : récepteur")
            try expectEqual(sender.state, .finished, "\(proto) : émetteur")
            try expectEqual(receiver.receivedFiles.first?.data, file.data, "\(proto) : fichier exact malgré les erreurs")
            try expect(sender.progress.retries >= 3, "\(proto) : reprises comptées (\(sender.progress.retries))")
            try expect(receiver.progress.retries >= 2, "\(proto) : NAK du récepteur (\(receiver.progress.retries))")
        }
    }

    suite.add("YMODEM : lot de deux fichiers, noms, tailles exactes, dates, pertes et EOT refusé") {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        // Le second finit par de vrais 0x1A : la taille de l'en-tête les garde.
        let files = [SerialFile(name: "cat9k_lite_iosxe.17.09.05.SPA.bin", data: pattern(3_072), modified: date),
                     SerialFile(name: "config.txt", data: Array("hostname SW-ETG2-01\n".utf8) + [0x1A, 0x1A])]
        let sender = XModemSender(proto: .ymodem, files: files)
        let receiver = XModemReceiver(proto: .ymodem)
        let link = SerialLink(sender: sender, receiver: receiver)
        var refusedEOT = false
        link.toSender = { index, bytes in
            // ACK de l'en-tête perdu (index 1) ; NAK forcé sur le premier EOT (récepteur prudent).
            if index == 1 { return nil }
            return bytes
        }
        link.toReceiver = { index, bytes in
            if bytes == [XModemByte.eot], !refusedEOT {
                refusedEOT = true
                return [0x00] // EOT abîmé en route : l'émetteur le renvoie après le délai
            }
            return bytes
        }
        try link.run()
        // Récepteur prudent qui refuse le premier EOT (NAK) : l'émetteur le renvoie aussitôt.
        let careful = XModemSender(proto: .xmodem, files: [SerialFile(name: "a", data: [1, 2, 3])])
        _ = careful.start(now: 0)
        try expectEqual(careful.receive([XModemByte.nak], now: 1).count, 132, "bloc 1 envoyé")
        try expectEqual(careful.receive([XModemByte.ack], now: 2), [XModemByte.eot], "EOT")
        try expectEqual(careful.receive([XModemByte.nak], now: 3), [XModemByte.eot], "EOT renvoyé après NAK")
        try expectEqual(careful.receive([XModemByte.ack], now: 4), [], "rien de plus")
        try expectEqual(careful.state, .finished, "terminé")
        try expectEqual(sender.state, .finished, "émetteur")
        try expectEqual(receiver.state, .finished, "récepteur (bloc 0 vide reçu)")
        try expectEqual(receiver.receivedFiles.map(\.name), files.map(\.name), "noms reçus")
        try expectEqual(receiver.receivedFiles.map(\.data), files.map(\.data), "contenus exacts (0x1A réels gardés)")
        try expectEqual(receiver.receivedFiles.first?.modified, date, "date gardée")
        try expectEqual(sender.progress.fileIndex, 2, "deux fichiers")
        try expect(sender.progress.retries >= 1, "reprise après la perte")
    }

    suite.add("XMODEM : annulation (utilisateur, appareil), délais dépassés, repli sur la somme, désynchronisation") {
        // L'utilisateur annule l'envoi au milieu : l'appareil reçoit CAN CAN.
        let file = SerialFile(name: "gros.bin", data: pattern(20_000))
        var sender = XModemSender(proto: .xmodem1K, files: [file])
        var receiver = XModemReceiver(proto: .xmodem1K)
        var link = SerialLink(sender: sender, receiver: receiver)
        link.afterSenderChunk = { index in index == 6 ? sender.cancel() : [] }
        try link.run()
        try expectEqual(sender.state, .cancelled(byPeer: false), "annulé par l’utilisateur")
        try expectEqual(receiver.state, .cancelled(byPeer: true), "l’appareil voit l’annulation")

        // L'appareil annule la réception.
        sender = XModemSender(proto: .xmodem, files: [file])
        receiver = XModemReceiver(proto: .xmodem)
        link = SerialLink(sender: sender, receiver: receiver)
        link.afterReceiverChunk = { index in index == 4 ? receiver.cancel() : [] }
        try link.run()
        try expectEqual(sender.state, .cancelled(byPeer: true), "annulé par l’appareil")

        // Personne en face : l'émetteur abandonne après 60 s sans « C » ni NAK.
        let lonely = XModemSender(proto: .xmodem, files: [file])
        _ = lonely.start(now: 0)
        try expectEqual(lonely.tick(now: 59), [], "attente")
        try expectEqual(lonely.tick(now: 60.5), XModem.cancelSequence, "abandon")
        if case .failed(let reason) = lonely.state { try expect(reason.contains("pas demandé"), "raison (\(reason))") } else {
            throw TestFailure(message: "échec attendu", file: #fileID, line: #line)
        }

        // Récepteur XMODEM-CRC sans réponse : « C » quatre fois, puis NAK (somme de contrôle).
        let waiting = XModemReceiver(proto: .xmodemCRC)
        var pokes = [waiting.start(now: 0)]
        for second in stride(from: 3.0, through: 15, by: 3) { pokes.append(waiting.tick(now: second)) }
        try expectEqual(pokes, [[0x43], [0x43], [0x43], [0x43], [0x15], [0x15]], "repli sur la somme")
        let block = XModem.block(number: 1, payload: Array("OK".utf8)[...], size: 128, crc: false)
        try expectEqual(waiting.receive(block, now: 16), [XModemByte.ack], "bloc avec somme accepté")
        try expectEqual(waiting.receive([XModemByte.eot], now: 16.1), [XModemByte.ack], "EOT acquitté")
        try expectEqual(waiting.receivedFiles.first?.data, Array("OK".utf8), "bourrage retiré")
        let silent = XModemReceiver(proto: .xmodem)
        _ = silent.start(now: 0)
        _ = silent.tick(now: 61)
        try expect(silent.state.isOver, "récepteur sans émetteur : abandon")

        // Bloc 3 alors qu'on attend le 1 : désynchronisé, annulation.
        let lost = XModemReceiver(proto: .xmodemCRC)
        _ = lost.start(now: 0)
        let out = lost.receive(XModem.block(number: 3, payload: [1][...], size: 128, crc: true), now: 1)
        try expectEqual(out, XModem.cancelSequence, "annulation")
        try expect(lost.state.isOver, "désynchronisé")

        // Ligne trop mauvaise : chaque bloc abîmé, abandon après dix reprises.
        sender = XModemSender(proto: .xmodem, files: [SerialFile(name: "x", data: pattern(500))])
        receiver = XModemReceiver(proto: .xmodem)
        link = SerialLink(sender: sender, receiver: receiver)
        link.toReceiver = { _, bytes in
            guard bytes.count > 100 else { return bytes }
            var copy = bytes
            copy[10] ^= 0xFF
            return copy
        }
        try link.run()
        try expect(receiver.state.isOver && sender.state.isOver, "abandon des deux côtés")
        if case .failed = receiver.state {} else if case .failed = sender.state {} else {
            throw TestFailure(message: "échec attendu : \(receiver.state) / \(sender.state)", file: #fileID, line: #line)
        }
    }
}

/// Données reconnaissables (pas de zéros en série, pas de 0x1A final).
private func pattern(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 * 31 + $0 / 7) % 251) | 0x01 }
}

/// Tuyau série simulé entre un émetteur et un récepteur, avec horloge simulée. Chaque envoi d'un
/// automate est un « morceau » numéroté que les fonctions `toReceiver` et `toSender` peuvent
/// abîmer, couper ou perdre (nil). Les morceaux sont remis en deux fois, pour éprouver la
/// lecture par morceaux.
private final class SerialLink {
    let sender: XModemSender
    let receiver: XModemReceiver
    var toReceiver: (Int, [UInt8]) -> [UInt8]? = { $1 }
    var toSender: (Int, [UInt8]) -> [UInt8]? = { $1 }
    var afterSenderChunk: (Int) -> [UInt8] = { _ in [] }
    var afterReceiverChunk: (Int) -> [UInt8] = { _ in [] }
    private var senderCount = 0
    private var receiverCount = 0
    private var now = 0.0

    init(sender: XModemSender, receiver: XModemReceiver) {
        self.sender = sender
        self.receiver = receiver
    }

    func run(limit: Double = 3_600) throws {
        var toR: [[UInt8]] = []
        var toS: [[UInt8]] = []
        func fromSender(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            senderCount += 1
            if let delivered = toReceiver(senderCount, bytes) { toR.append(delivered) }
            let extra = afterSenderChunk(senderCount)
            if !extra.isEmpty { toR.append(extra) }
        }
        func fromReceiver(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            receiverCount += 1
            if let delivered = toSender(receiverCount, bytes) { toS.append(delivered) }
            let extra = afterReceiverChunk(receiverCount)
            if !extra.isEmpty { toS.append(extra) }
        }
        fromSender(sender.start(now: now))
        fromReceiver(receiver.start(now: now))
        while now < limit {
            if sender.state.isOver && receiver.state.isOver && toR.isEmpty && toS.isEmpty { return }
            if !toR.isEmpty {
                let chunk = toR.removeFirst()
                let half = chunk.count / 2
                fromReceiver(receiver.receive(Array(chunk[..<half]), now: now))
                now += 0.01
                fromReceiver(receiver.receive(Array(chunk[half...]), now: now))
                continue
            }
            if !toS.isEmpty {
                fromSender(sender.receive(toS.removeFirst(), now: now))
                now += 0.01
                continue
            }
            // Ligne silencieuse : le temps passe, les délais jouent.
            now += 0.5
            fromSender(sender.tick(now: now))
            fromReceiver(receiver.tick(now: now))
        }
        throw TestFailure(message: "transfert jamais terminé (\(sender.state) / \(receiver.state))", file: #fileID, line: #line)
    }
}
