// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetScope",
    platforms: [.macOS(.v14)],
    targets: [
        // Moteur réseau, sans interface : Foundation, Network et Darwin seulement.
        .target(name: "NetScopeCore", linkerSettings: [.linkedLibrary("resolv")]),
        // Application SwiftUI.
        .executableTarget(name: "NetScope", dependencies: ["NetScopeCore"],
                         linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation")]),
        // Tests du moteur (exécutable, car XCTest n'est pas disponible sans Xcode).
        .executableTarget(name: "NetScopeSelfTest", dependencies: ["NetScopeCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
