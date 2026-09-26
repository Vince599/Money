// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "LedgerCore", targets: ["LedgerCore"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "LedgerCore"),
    .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore"])
]
#if !os(Windows)
dependencies.append(.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"))
products.append(.library(name: "LedgerStore", targets: ["LedgerStore"]))
targets.append(.target(name: "LedgerStore", dependencies: ["LedgerCore", .product(name: "GRDB", package: "GRDB.swift")]))
targets.append(.testTarget(name: "LedgerStoreTests", dependencies: ["LedgerStore", "LedgerCore", .product(name: "GRDB", package: "GRDB.swift")]))
#endif

let package = Package(
    name: "Ledger",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
