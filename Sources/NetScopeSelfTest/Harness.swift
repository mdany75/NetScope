import Foundation

// Petit harnais de test : XCTest n'est pas disponible sans Xcode.
// Aucun test n'accède au réseau, sauf éventuellement vers 127.0.0.1.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: Int
    var description: String { "\(message) (\(file):\(line))" }
}

/// Un scénario ignoré (outil indisponible dans cet environnement, par exemple).
struct TestSkipped: Error {
    let reason: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: String = #fileID, line: Int = #line) throws {
    if !condition() { throw TestFailure(message: message, file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                               file: String = #fileID, line: Int = #line) throws {
    if actual != expected {
        throw TestFailure(message: "\(message) — obtenu : \(actual), attendu : \(expected)", file: file, line: line)
    }
}

/// Vérifie que `body` lève l'erreur attendue.
func expectThrows<E: Error & Equatable>(_ expected: E, _ message: String,
                                        file: String = #fileID, line: Int = #line,
                                        _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as E {
        try expectEqual(error, expected, message, file: file, line: line)
        return
    } catch {
        throw TestFailure(message: "\(message) — erreur inattendue : \(error)", file: file, line: line)
    }
    throw TestFailure(message: "\(message) — aucune erreur levée", file: file, line: line)
}

final class TestSuite {
    struct Scenario {
        let name: String
        let body: () async throws -> Void
    }

    private(set) var scenarios: [Scenario] = []

    func add(_ name: String, _ body: @escaping () async throws -> Void) {
        scenarios.append(Scenario(name: name, body: body))
    }

    /// Exécute tous les scénarios ; renvoie le nombre d'échecs.
    func run() async -> Int {
        var failed = 0
        var skipped = 0
        for scenario in scenarios {
            do {
                try await scenario.body()
                print("OK     — \(scenario.name)")
            } catch let skip as TestSkipped {
                skipped += 1
                print("IGNORÉ — \(scenario.name) : \(skip.reason)")
            } catch {
                failed += 1
                print("ÉCHEC  — \(scenario.name) : \(error)")
            }
        }
        print("")
        print("\(scenarios.count) scénarios, \(scenarios.count - failed - skipped) réussis, \(failed) en échec, \(skipped) ignorés.")
        return failed
    }
}
