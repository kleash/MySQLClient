// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MySQLMacClient",
    // Required the moment a target ships a localized resource — SwiftPM
    // fails the manifest outright without it. "en" matches the String
    // Catalog's own source language and Info.plist's
    // CFBundleDevelopmentRegion.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MySQLMacClient", targets: ["MySQLMacClient"])
    ],
    dependencies: [
        // Fork of vapor/mysql-nio 1.9.1 pinned to an exact revision, adding
        // (1) CLIENT_MULTI_RESULTS + multi-result-set draining so a `CALL` to
        // a procedure that returns a SELECT works (upstream fails it with
        // ER_SP_BADSELECT), (2) result sets that carry their own columns,
        // so a SELECT matching zero rows still comes back with its headers
        // instead of being indistinguishable from an INSERT/USE/DDL, (3) a
        // refusal before the login when TLS was asked for and the server
        // doesn't offer it, and (4) packets of 16 MiB or more in both
        // directions. (3) and (4) are in stokay/mysql-nio#1; point this
        // back at stokay/mysql-nio once it's merged. See those commits'
        // messages for the full rationale.
        .package(
            url: "https://github.com/kleash/mysql-nio.git",
            revision: "5cf04ac12b467cc7ff6d07feed0b5ddbffca6bab"
        )
    ],
    targets: [
        .executableTarget(
            name: "MySQLMacClient",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio")
            ],
            resources: [
                .copy("Resources"),
                // `.process`, not `.copy` — a copied .xcstrings would ship as
                // raw JSON and localize nothing; processing runs it through
                // the String Catalog compiler. It also has to live *outside*
                // the `Resources/` folder above, since that whole directory
                // is copied verbatim.
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "MySQLMacClientTests",
            dependencies: ["MySQLMacClient"]
        )
    ]
)
