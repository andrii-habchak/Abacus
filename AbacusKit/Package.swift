// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "AbacusKit",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "AbacusDomain", targets: ["AbacusDomain"]),
    .library(name: "AbacusStore", targets: ["AbacusStore"]),
    .library(name: "AbacusFX", targets: ["AbacusFX"]),
    .library(name: "AbacusImport", targets: ["AbacusImport"]),
    .library(name: "AbacusFeatures", targets: ["AbacusFeatures"]),
    .executable(name: "abacus-import", targets: ["AbacusImportTool"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.9.0")
  ],
  targets: [
    // Entities (as @Table types), Money/Currency, contracts. Calc/ = pure calculators (WP A1).
    .target(
      name: "AbacusDomain",
      dependencies: [.product(name: "SQLiteData", package: "sqlite-data")]
    ),
    // Schema, migrations, repositories, queries (WP A5).
    .target(
      name: "AbacusStore",
      dependencies: ["AbacusDomain", .product(name: "SQLiteData", package: "sqlite-data")]
    ),
    // Rate providers, cache logic, converter, refresher (WP A2).
    .target(name: "AbacusFX", dependencies: ["AbacusDomain"]),
    // Core/ = contracts; Saldo/, PKO/ = parsers (A3, A4); Pipeline/, Dedupe/, Rules/ (A6).
    .target(name: "AbacusImport", dependencies: ["AbacusDomain"]),
    // Platform-neutral view models + PreviewData, shared by the macOS and iOS apps.
    .target(
      name: "AbacusFeatures",
      dependencies: ["AbacusDomain", "AbacusStore", "AbacusFX", "AbacusImport"]
    ),
    // Headless import into the app database with the wizard's defaults (no UI).
    .executableTarget(name: "AbacusImportTool", dependencies: ["AbacusImport", "AbacusStore"]),
    // Helpers shared by test targets: fixtures, real-sample lookup, test tags.
    .target(
      name: "AbacusTestSupport",
      dependencies: ["AbacusDomain", "AbacusStore"],
      path: "Tests/AbacusTestSupport"
    ),

    .testTarget(name: "AbacusDomainTests", dependencies: ["AbacusDomain", "AbacusTestSupport"]),
    .testTarget(name: "AbacusStoreTests", dependencies: ["AbacusStore", "AbacusTestSupport"]),
    .testTarget(name: "AbacusFXTests", dependencies: ["AbacusFX", "AbacusTestSupport"]),
    .testTarget(
      name: "AbacusImportTests",
      dependencies: ["AbacusImport", "AbacusStore", "AbacusTestSupport"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "AbacusFeaturesTests", dependencies: ["AbacusFeatures", "AbacusTestSupport"]),
  ]
)
