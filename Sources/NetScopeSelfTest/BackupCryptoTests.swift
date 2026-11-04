import Foundation
@testable import NetScopeCore

// Tests de la note 38 : sauvegarde chiffrée par mot de passe (PBKDF2-HMAC-SHA256, AES-GCM 256),
// secrets du Trousseau rangés seulement dans la partie chiffrée, faux Trousseau en mémoire.
// Uniquement des secrets fictifs, aucun accès réseau ni au vrai Trousseau.

/// Faux Trousseau : les secrets restent en mémoire.
final class MemorySecretStore: BackupSecretStore {
    var values: [String: Data] = [:]
    var refused: Set<String> = []

    func readSecrets() throws -> [BackupSecret] {
        values.keys.sorted().map { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return BackupSecret(service: parts[0], account: parts[1], value: values[key]!, usage: "essai")
        }
    }

    func write(_ secret: BackupSecret) throws {
        let key = secret.service + "|" + secret.account
        if refused.contains(key) { throw BackupError.corrupted("refusé") }
        values[key] = secret.value
    }
}

enum BackupCryptoFixtures {
    /// Itérations réduites au minimum accepté (les tests restent rapides) ; un test garde la valeur par défaut.
    static let iterations = BackupCrypto.iterationRange.lowerBound
    static let password = "Cheval-Agrafe-Batterie-42"
    static let fortiToken = "FICTIF-fgt-jeton-9f3c2b7a1e"
    static let snmpCommunity = "FICTIF-communaute-Zx81"
    static let smtpPassword = "FICTIF-smtp-Mdp!77"
    static let graphSecret = "FICTIF-graph-secret~Qw3"

    static var secrets: [BackupSecret] {
        [BackupSecret(service: "com.danymenard.netscope.fortigate", account: "6C1F3A52-0000-4000-8000-000000000001",
                      value: Data(fortiToken.utf8), usage: "Jeton de l’API REST de la FortiGate · Siège"),
         BackupSecret(service: "com.danymenard.netscope.snmp", account: "identifiants", value: Data(snmpCommunity.utf8), usage: "SNMP"),
         BackupSecret(service: "com.danymenard.netscope.alertes", account: AlertSecretKey.smtpPassword, value: Data(smtpPassword.utf8), usage: "SMTP"),
         BackupSecret(service: "com.danymenard.netscope.m365", account: "secret", value: Data(graphSecret.utf8), usage: "Graph")]
    }

    static var fictiveValues: [String] { [fortiToken, snmpCommunity, smtpPassword, graphSecret] }

    /// Vrai si l'une des valeurs fictives (en clair ou en base64, comme dans « secrets.json ») est dans `data`.
    static func containsSecret(_ data: Data) -> Bool {
        fictiveValues.contains { value in
            data.range(of: Data(value.utf8)) != nil || data.range(of: Data(Data(value.utf8).base64EncodedString().utf8)) != nil
        }
    }

    static func source(_ sandbox: BackupSandbox) throws -> BackupSource {
        var source = try sandbox.source()
        source.secrets = secrets
        return source
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

func registerBackupCryptoTests(_ suite: TestSuite) {
    typealias F = BackupCryptoFixtures

    suite.add("Sauvegarde chiffrée : PBKDF2-HMAC-SHA256 (vecteurs de référence)") {
        let salt = Data("salt".utf8)
        try expectEqual(F.hex(try BackupCrypto.pbkdf2(password: "password", salt: salt, iterations: 1)),
                        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", "1 itération")
        try expectEqual(F.hex(try BackupCrypto.pbkdf2(password: "password", salt: salt, iterations: 2)),
                        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", "2 itérations")
        try expectEqual(F.hex(try BackupCrypto.pbkdf2(password: "password", salt: salt, iterations: 4096)),
                        "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", "4096 itérations")
        // « é » composé ou décomposé : la même clé (forme NFC).
        try expectEqual(try BackupCrypto.pbkdf2(password: "caf\u{00E9}", salt: salt, iterations: 10),
                        try BackupCrypto.pbkdf2(password: "cafe\u{0301}", salt: salt, iterations: 10), "mot de passe normalisé")
    }

    suite.add("Sauvegarde chiffrée : aller-retour, en-tête et paramètres") {
        let plaintext = Data("contenu de l’archive".utf8)
        let sealed = try BackupCrypto.seal(plaintext, password: F.password, iterations: F.iterations, createdAt: Date(timeIntervalSince1970: 1_793_000_000),
                                           kind: .manuelle, appVersion: "0.14.0", appBuild: "140", fileCount: 4, preferenceCount: 2, secretCount: 0)
        try expect(sealed.prefix(16) == Data("NETSCOPE-CHIFFRE".utf8), "signature")
        try expect(BackupCrypto.isEncrypted(sealed) && !BackupCrypto.isEncrypted(Data("PK\u{3}\u{4}".utf8)), "détection")
        let (header, _) = try BackupCrypto.header(of: sealed)
        try expectEqual(header.format, "netscope-sauvegarde-chiffree", "format")
        try expectEqual(header.version, 1, "version de l'en-tête")
        try expectEqual(header.keyDerivation.algorithm, "PBKDF2-HMAC-SHA256", "dérivation")
        try expectEqual(header.cipher, "AES-GCM-256", "chiffrement")
        try expectEqual(header.keyDerivation.iterations, F.iterations, "itérations")
        try expectEqual(header.keyDerivation.salt.count, 16, "sel de 16 octets")
        try expectEqual(header.nonce.count, 12, "nonce de 12 octets")
        try expectEqual(header.fileCount, 4, "nombre de fichiers en clair")
        let opened = try BackupCrypto.open(sealed, password: F.password)
        try expectEqual(opened.plaintext, plaintext, "déchiffré à l'identique")
        try expect(sealed.range(of: plaintext) == nil, "contenu absent en clair")
        // Deux chiffrements du même contenu : sel et nonce différents.
        let again = try BackupCrypto.seal(plaintext, password: F.password, iterations: F.iterations, createdAt: Date(), kind: .manuelle,
                                          appVersion: "0.14.0", appBuild: "140", fileCount: 4, preferenceCount: 2, secretCount: 0)
        let other = try BackupCrypto.header(of: again).header
        try expect(other.keyDerivation.salt != header.keyDerivation.salt && other.nonce != header.nonce, "sel et nonce aléatoires")
        // Valeur par défaut : au moins 600 000 itérations ; dérivation affaiblie refusée.
        try expect(BackupCrypto.defaultIterations >= 600_000, "600 000 itérations par défaut")
        try expectThrows(BackupCryptoError.system("nombre d’itérations hors bornes"), "itérations trop faibles") {
            _ = try BackupCrypto.seal(plaintext, password: F.password, iterations: 1000, createdAt: Date(), kind: .manuelle,
                                      appVersion: "", appBuild: "", fileCount: 0, preferenceCount: 0, secretCount: 0)
        }
        try expectThrows(BackupCryptoError.emptyPassword, "mot de passe vide") {
            _ = try BackupCrypto.seal(plaintext, password: "", createdAt: Date(), kind: .manuelle,
                                      appVersion: "", appBuild: "", fileCount: 0, preferenceCount: 0, secretCount: 0)
        }
    }

    suite.add("Sauvegarde chiffrée : 600 000 itérations par défaut dans l'archive") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let info = try BackupEngine.create(try sandbox.source(), in: sandbox.backups, format: .zip, kind: .automatique,
                                           encryption: BackupEncryption(password: F.password, includeSecrets: false))
        try expectEqual(info.encryption?.keyDerivation.iterations, 600_000, "itérations de l'en-tête")
        try expectEqual(info.url.pathExtension, "netscope-backup", "extension")
        try expectEqual(info.format, .chiffree, "forme")
        _ = try BackupEngine.read(info.url, password: F.password)
    }

    suite.add("Sauvegarde chiffrée : mauvais mot de passe, rien n'est lu ni restauré") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let info = try BackupEngine.create(try F.source(sandbox), in: sandbox.backups, format: .zip, kind: .manuelle,
                                           encryption: BackupEncryption(password: F.password, includeSecrets: true, iterations: F.iterations))
        try expectThrows(BackupCryptoError.wrongPassword, "mauvais mot de passe") {
            _ = try BackupEngine.read(info.url, password: "Cheval-Agrafe-Batterie-43")
        }
        try expectThrows(BackupCryptoError.passwordRequired, "mot de passe absent") { _ = try BackupEngine.read(info.url) }
        try expectThrows(BackupCryptoError.passwordRequired, "mot de passe vide") { _ = try BackupEngine.read(info.url, password: "") }
        try expect(BackupCryptoError.wrongPassword.localizedDescription.contains("rien n’a été restauré"), "message clair")
        // La liste lit l'en-tête sans mot de passe.
        let listed = BackupEngine.list(in: sandbox.backups)
        try expectEqual(listed.count, 1, "listée sans mot de passe")
        try expect(listed[0].isEncrypted && listed[0].includesSecrets, "chiffrée, avec secrets")
        try expectEqual(listed[0].summary, "4 fichiers · 2 préférences · 4 secrets", "résumé")
        try expectEqual(listed[0].manifest.kind, .manuelle, "type en clair")
    }

    suite.add("Sauvegarde chiffrée : fichier modifié (intégrité), jamais de restauration partielle") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let info = try BackupEngine.create(try F.source(sandbox), in: sandbox.backups, format: .zip, kind: .manuelle,
                                           encryption: BackupEncryption(password: F.password, includeSecrets: true, iterations: F.iterations))
        let original = try Data(contentsOf: info.url)
        let (_, prefixLength) = try BackupCrypto.header(of: original)
        let url = sandbox.root.appendingPathComponent("modifiee.netscope-backup")
        // 1. Un octet chiffré changé (au milieu, puis dans l'étiquette).
        for offset in [prefixLength + (original.count - prefixLength) / 2, original.count - 1] {
            var bytes = [UInt8](original)
            bytes[offset] ^= 0x01
            try Data(bytes).write(to: url)
            try expectThrows(BackupCryptoError.tampered, "octet \(offset) modifié") { _ = try BackupEngine.read(url, password: F.password) }
        }
        // 2. L'en-tête en clair modifié (type « manuelle » → « securite ») : authentifié, donc refusé.
        let kindRange = original.prefix(prefixLength).range(of: Data("\"manuelle\"".utf8))
        try expect(kindRange != nil, "type dans l'en-tête")
        var forged = original.prefix(prefixLength)
        forged.replaceSubrange(kindRange!, with: Data("\"securite\"".utf8))
        try expectEqual(forged.count, prefixLength, "même longueur")
        forged.append(original[prefixLength...])
        try forged.write(to: url)
        try expectThrows(BackupCryptoError.tampered, "en-tête modifié") { _ = try BackupEngine.read(url, password: F.password) }
        // 3. Fichier tronqué.
        try original.prefix(prefixLength + 8).write(to: url)
        do {
            _ = try BackupEngine.read(url, password: F.password)
            throw TestFailure(message: "fichier tronqué accepté", file: #fileID, line: #line)
        } catch is BackupCryptoError {}
        // Le dossier de données n'a pas bougé : la lecture échoue avant toute écriture.
        try expectEqual(try String(contentsOf: sandbox.data.appendingPathComponent("etat.json"), encoding: .utf8), BackupSandbox.etat, "données intactes")
    }

    suite.add("Sauvegarde chiffrée : secrets seulement dans la partie chiffrée") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let source = try F.source(sandbox)
        // Avec secrets : aucun jeton fictif lisible dans les octets de l'archive.
        let withSecrets = try BackupEngine.create(source, in: sandbox.backups, format: .zip, kind: .manuelle,
                                                  encryption: BackupEncryption(password: F.password, includeSecrets: true, iterations: F.iterations))
        let raw = try Data(contentsOf: withSecrets.url)
        try expect(!F.containsSecret(raw), "jetons fictifs absents des octets de l'archive chiffrée")
        try expect(raw.range(of: Data("identifiants".utf8)) == nil && raw.range(of: Data("etat.json".utf8)) == nil,
                   "ni compte ni nom de fichier dans l'en-tête en clair")
        try expect(raw.range(of: Data(F.password.utf8)) == nil, "mot de passe jamais écrit")
        let contents = try BackupEngine.read(withSecrets.url, password: F.password)
        try expectEqual(contents.secrets, source.secrets.sorted { ($0.service, $0.account) < ($1.service, $1.account) }, "secrets relus")
        try expectEqual(contents.manifest.secrets?.count, 4, "secrets nommés dans le manifeste chiffré")
        try expectEqual(contents.manifest.encrypted, true, "manifeste marqué chiffré")
        // Chiffrée sans l'option : aucun secret.
        let without = try BackupEngine.create(source, in: sandbox.backups, format: .zip, kind: .manuelle, date: Date().addingTimeInterval(5),
                                              encryption: BackupEncryption(password: F.password, includeSecrets: false, iterations: F.iterations))
        try expect(!without.includesSecrets, "sans secret")
        let withoutSecrets = try BackupEngine.read(without.url, password: F.password).secrets
        try expect(withoutSecrets.isEmpty, "aucun secret relu")
        // Sans mot de passe : la sauvegarde habituelle, jamais de secret même si la source en a.
        for format in [BackupFormat.zip, .dossier] {
            let plain = try BackupEngine.create(source, in: sandbox.backups, format: format, kind: .manuelle, date: Date().addingTimeInterval(format == .zip ? 10 : 15))
            try expect(!plain.isEncrypted, "non chiffrée")
            var bytes = Data()
            if format == .zip {
                bytes = try Data(contentsOf: plain.url)
                let paths = try BackupZip.entries(of: bytes).map(\.path)
                try expect(!paths.contains(BackupEngine.secretsName), "pas de secrets.json")
            } else {
                for path in (FileManager.default.subpaths(atPath: plain.url.path) ?? []) {
                    bytes.append((try? Data(contentsOf: plain.url.appendingPathComponent(path))) ?? Data())
                }
                try expect(!FileManager.default.fileExists(atPath: plain.url.appendingPathComponent(BackupEngine.secretsName).path), "pas de secrets.json")
            }
            try expect(!F.containsSecret(bytes), "aucun jeton fictif dans la sauvegarde non chiffrée (\(format.rawValue))")
            try expect(plain.manifest.secrets == nil && plain.manifest.encrypted == nil, "manifeste d'avant inchangé")
        }
        // Archive en attente du redémarrage : non chiffrée, donc sans secret.
        let staged = try BackupEngine.plainArchive(of: contents)
        try expect(!F.containsSecret(staged), "archive en attente sans secret")
        let stagedURL = sandbox.root.appendingPathComponent("en-attente.zip")
        try staged.write(to: stagedURL)
        let restaged = try BackupEngine.read(stagedURL)
        try expectEqual(restaged.files, contents.files, "archive en attente relue")
        try expect(restaged.secrets.isEmpty, "aucun secret relu de l'archive en attente")
    }

    suite.add("Sauvegarde chiffrée : secrets remis dans un faux Trousseau") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let mac1 = MemorySecretStore()
        for secret in F.secrets { try mac1.write(secret) }
        var source = try sandbox.source()
        source.secrets = try mac1.readSecrets()
        let info = try BackupEngine.create(source, in: sandbox.backups, format: .zip, kind: .manuelle,
                                           encryption: BackupEncryption(password: F.password, includeSecrets: true, iterations: F.iterations))
        // Deuxième Mac : Trousseau vide, un ancien jeton à remplacer, un élément refusé.
        let mac2 = MemorySecretStore()
        mac2.values["com.danymenard.netscope.snmp|identifiants"] = Data("ancien".utf8)
        mac2.refused = ["com.danymenard.netscope.m365|secret"]
        let contents = try BackupEngine.read(info.url, password: F.password)
        let failed = BackupEngine.restoreSecrets(contents.secrets, to: mac2)
        try expectEqual(failed.map(\.service), ["com.danymenard.netscope.m365"], "échec signalé par compte")
        try expectEqual(mac2.values["com.danymenard.netscope.snmp|identifiants"], Data(F.snmpCommunity.utf8), "valeur remplacée")
        try expectEqual(mac2.values["com.danymenard.netscope.fortigate|6C1F3A52-0000-4000-8000-000000000001"], Data(F.fortiToken.utf8), "jeton FortiGate remis")
        try expectEqual(mac2.values.count, 3, "trois secrets écrits")
        // Un secret d'un autre service glissé dans une sauvegarde (même avec le bon mot de passe) : refusé.
        let evil = BackupSecret(service: "com.apple.account", account: "icloud", value: Data("x".utf8), usage: "")
        var manifest = contents.manifest
        manifest.secrets = [evil.item]
        let zip = BackupZip.archive([BackupZip.Entry(path: BackupEngine.manifestName, data: try BackupEngine.encoder().encode(manifest))]
                                    + contents.files.map { BackupZip.Entry(path: BackupEngine.filesFolder + "/" + $0.path, data: $0.data) }
                                    + [BackupZip.Entry(path: BackupEngine.secretsName, data: try BackupEngine.encoder().encode([evil]))])
        let forged = try BackupCrypto.seal(zip, password: F.password, iterations: F.iterations, createdAt: Date(), kind: .manuelle,
                                           appVersion: "0.14.0", appBuild: "140", fileCount: contents.files.count, preferenceCount: 0, secretCount: 1)
        let forgedURL = sandbox.root.appendingPathComponent("fabriquee.netscope-backup")
        try forged.write(to: forgedURL)
        try expectThrows(BackupError.corrupted("secret d’un autre service refusé"), "service étranger refusé") {
            _ = try BackupEngine.read(forgedURL, password: F.password)
        }
    }

    suite.add("Sauvegarde chiffrée : service de même préfixe sans point écarté, sauvegarde restaurable") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        try expect(BackupKeychainScan.isOwnService("com.danymenard.netscope.snmp"), "service de NetScope")
        try expect(!BackupKeychainScan.isOwnService("com.danymenard.netscope-dev"), "autre version de l'app")
        try expect(!BackupKeychainScan.isOwnService("com.danymenard.netscope"), "préfixe seul")
        let mac = MemorySecretStore()
        for secret in F.secrets { try mac.write(secret) }
        mac.values["com.danymenard.netscope-dev|jeton"] = Data("FICTIF-dev".utf8)
        var source = try sandbox.source()
        source.secrets = try mac.readSecrets()
        let info = try BackupEngine.create(source, in: sandbox.backups, format: .zip, kind: .manuelle,
                                           encryption: BackupEncryption(password: F.password, includeSecrets: true, iterations: F.iterations))
        let contents = try BackupEngine.read(info.url, password: F.password)
        try expect(!contents.secrets.contains { $0.service == "com.danymenard.netscope-dev" }, "service étranger non rangé")
        try expectEqual(contents.secrets.count, F.secrets.count, "secrets de NetScope gardés")
        try expectThrows(BackupCryptoError.emptyPassword, "mot de passe vide : erreur, pas de plantage") {
            _ = try BackupCrypto.pbkdf2(password: "", salt: Data(repeating: 1, count: 16), iterations: F.iterations)
        }
    }

    suite.add("Sauvegarde chiffrée : ancienne sauvegarde non chiffrée toujours restaurable") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        // Archive de la 0.13.0 : manifeste sans les champs « encrypted » ni « secrets ».
        let old = try BackupEngine.create(try sandbox.source(), in: sandbox.backups, format: .zip, kind: .automatique)
        var entries = try BackupZip.entries(of: try Data(contentsOf: old.url))
        let manifestIndex = entries.firstIndex { $0.path == BackupEngine.manifestName }!
        var json = try JSONSerialization.jsonObject(with: entries[manifestIndex].data) as! [String: Any]
        json.removeValue(forKey: "encrypted")
        json.removeValue(forKey: "secrets")
        entries[manifestIndex].data = try JSONSerialization.data(withJSONObject: json)
        let url = sandbox.backups.appendingPathComponent("NetScope-sauvegarde-2026-11-01-080000-auto.zip")
        try BackupZip.archive(entries).write(to: url)
        let info = try BackupEngine.info(at: url)
        try expect(!info.isEncrypted && info.format == .zip, "listée comme avant")
        let contents = try BackupEngine.read(url)
        try expectEqual(contents.files.count, 4, "fichiers relus")
        try expect(contents.secrets.isEmpty && contents.encryption == nil, "aucun secret")
        // Un mot de passe donné par erreur est sans effet sur une sauvegarde non chiffrée.
        try expectEqual(try BackupEngine.read(url, password: F.password).files, contents.files, "mot de passe ignoré")
        let target = sandbox.root.appendingPathComponent("Restauree", isDirectory: true)
        try BackupEngine.restoreFiles(contents, to: target)
        try expectEqual(try String(contentsOf: target.appendingPathComponent("etat.json"), encoding: .utf8), BackupSandbox.etat, "restaurée")
    }

    suite.add("Sauvegarde chiffrée : tous les sites, inventaires et résultats") {
        let sandbox = try BackupSandbox()
        defer { sandbox.remove() }
        let manager = FileManager.default
        let siege = UUID(uuidString: "6C1F3A52-0000-4000-8000-0000000000A1")!, laval = UUID(uuidString: "6C1F3A52-0000-4000-8000-0000000000B2")!
        let sites = #"{"version":1,"sites":[{"id":"\#(siege.uuidString)","name":"Siège"},{"id":"\#(laval.uuidString)","name":"Laval"}]}"#
        try Data(sites.utf8).write(to: sandbox.data.appendingPathComponent("sites.json"))
        var expected: [String: Data] = [:]
        for (id, n) in [(siege, 212), (laval, 48)] {
            let folder = sandbox.data.appendingPathComponent("sites/\(id.uuidString)", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let inventory = Data(#"{"version":2,"devices":[\#((0..<n).map { #"{"ip":"10.0.0.\#($0 % 250)"}"# }.joined(separator: ","))]}"#.utf8)
            let results = Data(#"{"rows":\#(n)}"#.utf8)
            try inventory.write(to: folder.appendingPathComponent("inventory.json"))
            try results.write(to: folder.appendingPathComponent("resultats.json"))
            expected["sites/\(id.uuidString)/inventory.json"] = inventory
            expected["sites/\(id.uuidString)/resultats.json"] = results
        }
        expected["sites.json"] = Data(sites.utf8)
        let info = try BackupEngine.create(try F.source(sandbox), in: sandbox.backups, format: .dossier, kind: .manuelle,
                                           encryption: BackupEncryption(password: F.password, includeSecrets: true, iterations: F.iterations))
        try expectEqual(info.encryption?.fileCount, 9, "4 fichiers d'origine, sites.json et 2 × 2 fichiers de site")
        let contents = try BackupEngine.read(info.url, password: F.password)
        let target = sandbox.root.appendingPathComponent("AutreMac", isDirectory: true)
        try BackupEngine.restoreFiles(contents, to: target)
        for (path, data) in expected {
            try expectEqual(try Data(contentsOf: target.appendingPathComponent(path)), data, "« \(path) » restauré")
        }
        try expect(!manager.fileExists(atPath: target.appendingPathComponent(BackupEngine.secretsName).path), "secrets jamais écrits en fichier")
    }

    suite.add("Sauvegarde chiffrée : force du mot de passe") {
        typealias S = BackupPasswordStrength
        try expectEqual(S.evaluate("").level, .vide, "vide")
        try expectEqual(S.evaluate("abc123").level, .tropCourt, "trop court")
        try expect(!S.evaluate("abc123").isAcceptable, "refusé")
        try expect(S.evaluate("motdepasse1").level <= .faible, "mot courant")
        try expect(S.evaluate("aaaaaaaaaaaa").level == .faible, "répétition")
        try expect(S.evaluate("Lune7-Fenetre").level >= .moyen, "moyen")
        try expect(S.evaluate(F.password).level >= .bon, "phrase de passe")
        try expect(S.evaluate("Cheval agrafe batterie correcte, 1984 !").level == .excellent, "longue phrase")
        try expect(S.evaluate("abcdefgh").isAcceptable, "8 caractères acceptés")
    }
}
