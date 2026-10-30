// swift-tools-version:6.0
// Taby nativ (macOS, SwiftUI). Baut nur mit den Command Line Tools (kein
// Xcode nötig). Tests laufen als eigenes Programm `swift run TabyChecks`,
// weil XCTest/swift-testing ohne Xcode nicht verfügbar sind.
import Foundation
import PackageDescription

// Matrix Rust SDK (Element-X-Schicht): nur wenn scripts/build-matrix-sdk.sh die
// Bibliothek nach Vendor/MatrixSDK gebaut hat. Ohne sie baut das Paket wie bisher.
let matrixRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("Vendor/MatrixSDK").path
let hasMatrix = FileManager.default.fileExists(atPath: matrixRoot + "/lib/libmatrix_sdk_ffi.a")
let matrixDependencies: [Target.Dependency] = hasMatrix ? ["MatrixSDK"] : []
let matrixSwiftSettings: [SwiftSetting] = hasMatrix ? [.define("TABY_MATRIX")] : []
let matrixTargets: [Target] = hasMatrix ? [
  // Modulkarte der C-Schnittstelle (Vendor/MatrixSDK/include/module.modulemap).
  .systemLibrary(name: "matrix_sdk_ffiFFI", path: "Vendor/MatrixSDK/include"),
  // Generierte Swift-Bindings plus statische Bibliothek (universal arm64 + x86_64).
  .target(
    name: "MatrixSDK",
    dependencies: ["matrix_sdk_ffiFFI"],
    path: "Vendor/MatrixSDK/Swift",
    linkerSettings: [
      .unsafeFlags(["-L", matrixRoot + "/lib"]),
      .linkedLibrary("matrix_sdk_ffi"),
      .linkedLibrary("c++"),
      .linkedLibrary("resolv"),
      .linkedFramework("SystemConfiguration"),
      .linkedFramework("Security"),
      .linkedFramework("CoreFoundation"),
    ]
  ),
] : []

let package = Package(
  name: "Taby",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Taby", targets: ["TabyApp"]),
    .executable(name: "TabyChecks", targets: ["TabyChecks"]),
    .executable(name: "taby-hook-relay", targets: ["TabyHookRelay"]),
    .executable(name: "taby-mcp", targets: ["TabyMCP"]),
  ],
  targets: [
    // Kern ohne Oberfläche: Verträge, Speicher, Werkzeuge, Modell, Planer,
    // Kalender, Claude-Code-Anbindung. Prüfungen liegen je Bereich daneben.
    .target(
      name: "TabyCore",
      dependencies: matrixDependencies,
      swiftSettings: matrixSwiftSettings,
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        // Apple Intelligence gibt es erst ab macOS 26: schwach linken, damit
        // Taby auf macOS 14/15 startet (Nutzung hinter #available).
        .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
      ]
    ),
    // SwiftUI-Oberfläche: Notch-Insel, Maskottchen, Ansichten.
    .target(name: "TabyUI", dependencies: ["TabyCore"]),
    // App-Start und Verdrahtung (Orchestrator/Integrator).
    .executableTarget(name: "TabyApp", dependencies: ["TabyCore", "TabyUI"]),
    // Prüfprogramm: führt alle CheckSuites aus TabyCore und TabyUI aus.
    .executableTarget(name: "TabyChecks", dependencies: ["TabyCore", "TabyUI"]),
    // Wird von Claude Codes PermissionRequest-Hook gestartet und reicht die
    // Anfrage per Unix-Socket an die laufende App weiter.
    .executableTarget(name: "TabyHookRelay"),
    // MCP-Server (stdio) für Hermes/Claude: wird vom MCP-Client gestartet und
    // reicht Werkzeug-Aufrufe per Unix-Socket an die laufende App weiter.
    .executableTarget(name: "TabyMCP", dependencies: ["TabyCore"]),
  ] + matrixTargets,
  swiftLanguageModes: [.v5]
)
