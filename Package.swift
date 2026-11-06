// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetScope",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NetScope", targets: ["NetScope"]),
        // Note 64 : agent sans fenêtre (LaunchAgent du paquet), moteur seulement.
        .executable(name: "NetScopeAgent", targets: ["NetScopeAgent"]),
        .executable(name: "NetScopeSelfTest", targets: ["NetScopeSelfTest"]),
    ],
    targets: [
        // Moteur réseau, sans interface : Foundation, Network et Darwin seulement.
        .target(name: "NetScopeCore", linkerSettings: [.linkedLibrary("resolv")]),
        // Application SwiftUI.
        .executableTarget(name: "NetScope", dependencies: ["NetScopeCore"],
                         linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation"), .linkedFramework("IOKit")]),
        // Note 64 : agent sans fenêtre (sondes, Syslog, scans planifiés quand l'app est fermée).
        .executableTarget(name: "NetScopeAgent", dependencies: ["NetScopeCore"]),
        // Tests du moteur (exécutable, car XCTest n'est pas disponible sans Xcode).
        .executableTarget(name: "NetScopeSelfTest", dependencies: ["NetScopeCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
